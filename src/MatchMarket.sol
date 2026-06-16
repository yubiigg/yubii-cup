// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";

import {OutcomeToken} from "./OutcomeToken.sol";
import {YubiiToken} from "./YubiiToken.sol";
import {IOptimisticOracleV3, IOptimisticOracleV3CallbackRecipient} from "./interfaces/IOptimisticOracleV3.sol";

contract MatchMarket is IUnlockCallback, IOptimisticOracleV3CallbackRecipient {
    // ─────────────────────── constants ───────────────────────────────────────

    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant TICK_LOWER = -887220;
    int24 internal constant TICK_UPPER = 887220;
    uint160 internal constant INITIAL_SQRT_PRICE = 79228162514264337593543950336;
    uint64 internal constant OO_LIVENESS = 7200;
    bytes32 internal constant OO_IDENTIFIER = bytes32("ASSERT_TRUTH");

    // ── dynamic fee ───────────────────────────────────────────────────────────
    uint256 internal constant FEE_MIN_BPS = 30;      // protocol fee floor (0.30%)
    uint256 internal constant FEE_SCALE   = 1 ether; // ewmaVolume level that saturates to profile max
    uint256 internal constant HALF_LIFE   = 100;     // EWMA decay half-life in blocks

    uint256 internal constant PROFILE_MAX_SOFT       = 100; // max fee bps — SOFT
    uint256 internal constant PROFILE_MAX_BALANCED   = 300; // max fee bps — BALANCED
    uint256 internal constant PROFILE_MAX_AGGRESSIVE = 500; // max fee bps — AGGRESSIVE

    uint8 internal constant ACT_INIT = 0;
    uint8 internal constant ACT_BUY = 1;
    uint8 internal constant ACT_SELL = 2;
    uint8 internal constant ACT_REMOVE = 3;

    // ─────────────────────── immutables ──────────────────────────────────────

    IPoolManager private immutable poolManager;
    YubiiToken private immutable yubiiToken;
    address private immutable feeRecipient;
    IOptimisticOracleV3 public immutable oracle;
    address private immutable factory;
    address private immutable owner;

    OutcomeToken public immutable tokenA;
    OutcomeToken public immutable tokenB;
    PoolKey private poolKeyA;
    PoolKey private poolKeyB;

    string public teamA;
    string public teamB;
    uint256 public kickoffTime;

    // ─────────────────────── state ───────────────────────────────────────────

    uint128 public liquidityA;
    uint128 public liquidityB;

    bool private liquidityInitialized;
    bool public settled;
    bool private pinkyBroken;
    bool public held;
    bool public kickedAfter;
    bool public limitsRemoved;
    uint8  public feeProfile;       // 0=SOFT 1=BALANCED 2=AGGRESSIVE (default: BALANCED)
    uint256 public ewmaVolume;      // EWMA of ETH buy volume (wei)
    uint256 public lastVolumeBlock; // block.number of last EWMA update
    uint256 public maxBuyETH = 0.01 ether;
    uint256 public buyTaxBps = 2000;
    uint256 public sellTaxBps = 2000;
    address public marketingWallet;
    uint8 public winner; // 1 = teamA, 2 = teamB
    uint256 public totalSettledETH;
    uint256 public settledWinnerSupply; // winner token supply snapshot at settlement

    bytes32 public pendingAssertionId;
    uint8 public pendingWinner;

    // ─────────────────────── events ──────────────────────────────────────────

    event Buy(address indexed user, bool indexed isTeamA, uint256 ethIn, uint256 tokensOut, uint256 yubiiFee);
    event Sell(address indexed user, bool indexed isTeamA, uint256 tokensIn, uint256 ethOut, uint256 yubiiFee);
    event SettlementRequested(bytes32 assertionId, uint8 claimedWinner);
    event Settled(uint8 winner, uint256 totalETH);
    event Redeemed(address indexed user, uint256 tokensIn, uint256 ethOut);
    event BreakPinky(address indexed to, uint256 ethAmount);
    event KickAfter(address indexed owner, uint256 amount, uint256 timestamp);
    event MarketHeld();
    event MarketResumed();
    event FeeProfileSet(uint8 profile);

    // ─────────────────────── errors ──────────────────────────────────────────

    error OnlyPoolManager();
    error OnlyOracle();
    error OnlyFactory();
    error OnlyOwner();
    error MarketSettled();
    error MarketNotSettled();
    error TooEarly();
    error KickoffPassed();
    error AssertionPending();
    error SlippageExceeded();
    error InvalidWinner();
    error ZeroAmount();
    error InsufficientValue();
    error PinkyBroken();
    error BuyLimitExceeded();
    error TaxTooHigh();
    error MatchHeld();
    error CannotReclaimOutcomeToken();
    error InvalidFeeProfile();

    // ─────────────────────── structs ─────────────────────────────────────────

    struct InitParams {
        uint256 ethA;
        uint256 tokenMintA;
        uint256 ethB;
        uint256 tokenMintB;
    }

    struct BuyParams {
        bool isTeamA;
        address user;
        uint256 minOut;
        uint256 ethIn;
    }

    struct SellParams {
        bool isTeamA;
        address user;
        uint256 amountIn;
        uint256 minEthOut;
    }

    // ─────────────────────── constructor ─────────────────────────────────────

    constructor(
        address _poolManager,
        address _yubiiToken,
        address _feeRecipient,
        address _oracle,
        string memory _teamA,
        string memory _teamB,
        uint256 _kickoffTime,
        address _owner,
        address _marketingWallet,
        uint8 _feeProfile
    ) payable {
        if (_feeProfile > 2) revert InvalidFeeProfile();
        factory = msg.sender;
        owner = _owner;
        marketingWallet = _marketingWallet;
        feeProfile = _feeProfile;
        lastVolumeBlock = block.number;
        poolManager = IPoolManager(_poolManager);
        yubiiToken = YubiiToken(_yubiiToken);
        feeRecipient = _feeRecipient;
        oracle = IOptimisticOracleV3(_oracle);
        teamA = _teamA;
        teamB = _teamB;
        kickoffTime = _kickoffTime;

        // Deploy outcome tokens (market address is this)
        tokenA = new OutcomeToken(_teamA, _toSymbol(_teamA), address(this));
        tokenB = new OutcomeToken(_teamB, _toSymbol(_teamB), address(this));

        // Sort currencies: ETH (address(0)) < any ERC20 address (always)
        Currency eth = CurrencyLibrary.ADDRESS_ZERO;
        Currency currA = Currency.wrap(address(tokenA));
        Currency currB = Currency.wrap(address(tokenB));

        poolKeyA = PoolKey({
            currency0: eth,
            currency1: currA,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        poolKeyB = PoolKey({
            currency0: eth,
            currency1: currB,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        // Initialize pools (no unlock needed)
        IPoolManager(_poolManager).initialize(poolKeyA, INITIAL_SQRT_PRICE);
        IPoolManager(_poolManager).initialize(poolKeyB, INITIAL_SQRT_PRICE);

        // ETH held in contract; factory must call initializeLiquidity() after deployment
    }

    // ─────────────────────── external: initialize ────────────────────────────

    function initializeLiquidity() external {
        require(msg.sender == factory, "Only factory");
        require(!liquidityInitialized, "Already initialized");
        liquidityInitialized = true;
        if (address(this).balance > 0) {
            _seedLiquidity(address(this).balance);
        }
    }

    // ─────────────────────── external: owner admin ───────────────────────────

    function removeLimits() external {
        if (msg.sender != owner) revert OnlyOwner();
        limitsRemoved = true;
    }

    function reduceTax(uint256 newBuy, uint256 newSell) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (newBuy > 500 || newSell > 500) revert TaxTooHigh();
        buyTaxBps = newBuy;
        sellTaxBps = newSell;
    }

    function removeTax() external {
        if (msg.sender != owner) revert OnlyOwner();
        buyTaxBps = 0;
        sellTaxBps = 0;
    }

    function setFeeProfile(uint8 profile) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (profile > 2) revert InvalidFeeProfile();
        feeProfile = profile;
        emit FeeProfileSet(profile);
    }

    function holdMatch() external {
        if (msg.sender != owner && msg.sender != factory) revert OnlyOwner();
        held = true;
        emit MarketHeld();
    }

    function resumeMatch() external {
        if (msg.sender != owner && msg.sender != factory) revert OnlyOwner();
        held = false;
        emit MarketResumed();
    }

    function reclaimETH(address to, uint256 amount) external {
        if (msg.sender != owner) revert OnlyOwner();
        require(held || pinkyBroken || settled, "Not held, pinkyBroken, or settled");
        (bool ok,) = payable(to).call{value: amount}("");
        require(ok, "ETH transfer failed");
    }

    function reclaimToken(address token, address to, uint256 amount) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (token == address(tokenA) || token == address(tokenB)) revert CannotReclaimOutcomeToken();
        IERC20(token).transfer(to, amount);
    }

    // ─────────────────────── external: emergency ─────────────────────────────

    function breakPinky() external {
        if (msg.sender != owner) revert OnlyOwner();
        if (settled) revert MarketSettled();
        if (pinkyBroken) revert PinkyBroken();
        if (block.timestamp >= kickoffTime) revert KickoffPassed();

        pinkyBroken = true;

        // Remove all LP; _takeRemoved burns any returned outcome tokens
        poolManager.unlock(abi.encode(ACT_REMOVE, bytes("")));

        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool ok,) = payable(owner).call{value: bal}("");
            require(ok, "ETH transfer failed");
        }

        emit BreakPinky(owner, bal);
    }

    // Emergency last-resort function for crisis scenarios (technical failure, match
    // cancellation, dispute, oracle malfunction) where the owner needs to recover all
    // pooled ETH — including funds from user buys — to manually refund users off-chain
    // or via a separate claim process. Unlike breakPinky() which only works before
    // kickoff, kickAfter() works at any time post-kickoff as long as the match is held
    // and not yet settled.
    function kickAfter() external {
        if (msg.sender != owner) revert OnlyOwner();
        require(held, "Must holdMatch() first");
        require(!settled, "Already settled");
        require(!kickedAfter, "Already kicked after");

        kickedAfter = true;

        poolManager.unlock(abi.encode(ACT_REMOVE, bytes("")));

        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool ok,) = payable(owner).call{value: bal}("");
            require(ok, "ETH transfer failed");
        }

        emit KickAfter(owner, bal, block.timestamp);
    }

    // ─────────────────────── external: trading ────────────────────────────────

    function buy(bool isTeamA, uint256 minOut) external payable {
        if (settled || pinkyBroken) revert MarketSettled();
        if (held) revert MatchHeld();
        if (msg.value == 0) revert ZeroAmount();
        if (!limitsRemoved && msg.value > maxBuyETH) revert BuyLimitExceeded();

        uint256 tax = (msg.value * buyTaxBps) / 10000;
        if (tax > 0) {
            (bool ok,) = payable(marketingWallet).call{value: tax}("");
            require(ok, "Tax transfer failed");
        }

        uint256 feeBps = currentFeeBps();
        {
            uint256 bd = block.number > lastVolumeBlock ? block.number - lastVolumeBlock : 0;
            ewmaVolume      = _decayEwma(ewmaVolume, bd) + msg.value;
            lastVolumeBlock = block.number;
        }
        uint256 yubiiFee = (msg.value * feeBps) / 10000;
        if (yubiiFee > 0) {
            yubiiToken.transferFrom(msg.sender, feeRecipient, yubiiFee);
        }

        bytes memory result = poolManager.unlock(
            abi.encode(ACT_BUY, abi.encode(BuyParams({
                isTeamA: isTeamA,
                user: msg.sender,
                minOut: minOut,
                ethIn: msg.value - tax
            })))
        );

        uint256 tokensOut = abi.decode(result, (uint256));
        if (tokensOut < minOut) revert SlippageExceeded();

        emit Buy(msg.sender, isTeamA, msg.value, tokensOut, yubiiFee);
    }

    function sell(bool isTeamA, uint256 amountIn, uint256 minEthOut) external {
        if (settled || pinkyBroken) revert MarketSettled();
        if (held) revert MatchHeld();
        if (amountIn == 0) revert ZeroAmount();

        uint256 yubiiFee = (amountIn * currentFeeBps()) / 10000;
        if (yubiiFee > 0) {
            yubiiToken.transferFrom(msg.sender, feeRecipient, yubiiFee);
        }

        bytes memory result = poolManager.unlock(
            abi.encode(ACT_SELL, abi.encode(SellParams({
                isTeamA: isTeamA,
                user: msg.sender,
                amountIn: amountIn,
                minEthOut: minEthOut
            })))
        );

        uint256 ethOut = abi.decode(result, (uint256));
        if (ethOut < minEthOut) revert SlippageExceeded();

        emit Sell(msg.sender, isTeamA, amountIn, ethOut, yubiiFee);
    }

    // ─────────────────────── external: settlement ────────────────────────────

    function requestSettlement(uint8 claimedWinner, address asserter, address bondCurrency, uint256 bond)
        external
        returns (bytes32 assertionId)
    {
        if (settled || pinkyBroken) revert MarketSettled();
        if (block.timestamp < kickoffTime) revert TooEarly();
        if (pendingAssertionId != bytes32(0)) revert AssertionPending();
        if (claimedWinner != 1 && claimedWinner != 2) revert InvalidWinner();

        string memory winnerName = claimedWinner == 1 ? teamA : teamB;
        bytes memory claim = abi.encodePacked(
            "Team ", winnerName, " won the match. kickoffTime: ", _uintToStr(kickoffTime)
        );

        if (bond > 0) {
            IERC20(bondCurrency).transferFrom(asserter, address(this), bond);
            IERC20(bondCurrency).approve(address(oracle), bond);
        }

        assertionId = oracle.assertTruth(
            claim,
            asserter,
            address(this),
            address(0),
            OO_LIVENESS,
            bondCurrency,
            bond,
            OO_IDENTIFIER,
            bytes32(0)
        );

        pendingAssertionId = assertionId;
        pendingWinner = claimedWinner;

        emit SettlementRequested(assertionId, claimedWinner);
    }

    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external {
        if (msg.sender != address(oracle)) revert OnlyOracle();
        if (assertionId != pendingAssertionId) return;

        pendingAssertionId = bytes32(0);

        if (assertedTruthfully) {
            _executeSettlement(pendingWinner);
        }
        // If disputed/rejected: state resets, new assertion can be submitted
    }

    function assertionDisputedCallback(bytes32 assertionId) external {
        if (msg.sender != address(oracle)) revert OnlyOracle();
        if (assertionId == pendingAssertionId) {
            pendingAssertionId = bytes32(0);
            pendingWinner = 0;
        }
    }

    // ─────────────────────── external: redemption ────────────────────────────

    function redeem(uint256 amount) external {
        if (!settled) revert MarketNotSettled();
        if (amount == 0) revert ZeroAmount();

        OutcomeToken winnerToken = winner == 1 ? tokenA : tokenB;
        uint256 ethOut = (amount * totalSettledETH) / settledWinnerSupply;

        winnerToken.burn(msg.sender, amount);

        (bool ok,) = payable(msg.sender).call{value: ethOut}("");
        require(ok, "ETH transfer failed");

        emit Redeemed(msg.sender, amount, ethOut);
    }

    // ─────────────────────── dynamic fee ─────────────────────────────────────

    function currentFeeBps() public view returns (uint256) {
        uint256 blocksDelta = block.number > lastVolumeBlock ? block.number - lastVolumeBlock : 0;
        uint256 decayed     = _decayEwma(ewmaVolume, blocksDelta);
        uint256 maxBps      = feeProfile == 0 ? PROFILE_MAX_SOFT
                            : feeProfile == 1 ? PROFILE_MAX_BALANCED
                            : PROFILE_MAX_AGGRESSIVE;
        uint256 fee         = FEE_MIN_BPS + (maxBps - FEE_MIN_BPS) * decayed / FEE_SCALE;
        return fee > maxBps ? maxBps : fee;
    }

    function _decayEwma(uint256 ewma, uint256 blocksDelta) internal pure returns (uint256) {
        if (ewma == 0 || blocksDelta == 0) return ewma;
        if (blocksDelta >= HALF_LIFE * 7) return 0;
        return ewma >> (blocksDelta / HALF_LIFE); // halve for each complete half-life elapsed
    }

    // ─────────────────────── IUnlockCallback ─────────────────────────────────

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        (uint8 action, bytes memory params) = abi.decode(data, (uint8, bytes));

        if (action == ACT_INIT) {
            _handleInit(params);
            return "";
        } else if (action == ACT_BUY) {
            return _handleBuy(params);
        } else if (action == ACT_SELL) {
            return _handleSell(params);
        } else if (action == ACT_REMOVE) {
            _handleRemove();
            return "";
        }
        revert("Unknown action");
    }

    // ─────────────────────── internal: unlock handlers ───────────────────────

    function _handleInit(bytes memory rawParams) internal {
        InitParams memory p = abi.decode(rawParams, (InitParams));

        uint128 liqA = _computeLiquidity(p.ethA, p.tokenMintA);
        uint128 liqB = _computeLiquidity(p.ethB, p.tokenMintB);

        // Add liquidity to TeamA pool
        (BalanceDelta deltaA,) = poolManager.modifyLiquidity(
            poolKeyA,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(uint256(liqA)),
                salt: bytes32(0)
            }),
            ""
        );

        // Settle TeamA pool debts
        _settleAdd(deltaA, Currency.wrap(address(tokenA)));

        // Add liquidity to TeamB pool
        (BalanceDelta deltaB,) = poolManager.modifyLiquidity(
            poolKeyB,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(uint256(liqB)),
                salt: bytes32(0)
            }),
            ""
        );

        // Settle TeamB pool debts
        _settleAdd(deltaB, Currency.wrap(address(tokenB)));

        liquidityA = liqA;
        liquidityB = liqB;
    }

    function _handleBuy(bytes memory rawParams) internal returns (bytes memory) {
        BuyParams memory p = abi.decode(rawParams, (BuyParams));

        PoolKey memory key = p.isTeamA ? poolKeyA : poolKeyB;
        Currency tokenCurrency = p.isTeamA
            ? Currency.wrap(address(tokenA))
            : Currency.wrap(address(tokenB));

        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(p.ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );

        // delta.amount0() < 0 → owe ETH; delta.amount1() > 0 → receive tokens
        int256 a0 = delta.amount0();
        int256 a1 = delta.amount1();

        if (a0 < 0) {
            poolManager.settle{value: uint256(-a0)}();
        }

        uint256 tokensOut = 0;
        if (a1 > 0) {
            tokensOut = uint256(a1);
            poolManager.take(tokenCurrency, p.user, tokensOut);
        }

        return abi.encode(tokensOut);
    }

    function _handleSell(bytes memory rawParams) internal returns (bytes memory) {
        SellParams memory p = abi.decode(rawParams, (SellParams));

        PoolKey memory key = p.isTeamA ? poolKeyA : poolKeyB;
        OutcomeToken token = p.isTeamA ? tokenA : tokenB;
        Currency tokenCurrency = Currency.wrap(address(token));

        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(p.amountIn),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        // delta.amount1() < 0 → owe tokens; delta.amount0() > 0 → receive ETH
        int256 a0 = delta.amount0();
        int256 a1 = delta.amount1();

        if (a1 < 0) {
            uint256 tokensOwed = uint256(-a1);
            poolManager.sync(tokenCurrency);
            token.transferFrom(p.user, address(poolManager), tokensOwed);
            poolManager.settle();
        }

        uint256 ethOut = 0;
        if (a0 > 0) {
            uint256 gross = uint256(a0);
            uint256 tax = (gross * sellTaxBps) / 10000;
            ethOut = gross - tax;
            if (ethOut > 0) {
                poolManager.take(CurrencyLibrary.ADDRESS_ZERO, p.user, ethOut);
            }
            if (tax > 0) {
                poolManager.take(CurrencyLibrary.ADDRESS_ZERO, marketingWallet, tax);
            }
        }

        return abi.encode(ethOut);
    }

    function _handleRemove() internal {
        // Remove TeamA pool liquidity
        if (liquidityA > 0) {
            (BalanceDelta deltaA,) = poolManager.modifyLiquidity(
                poolKeyA,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: TICK_LOWER,
                    tickUpper: TICK_UPPER,
                    liquidityDelta: -int256(uint256(liquidityA)),
                    salt: bytes32(0)
                }),
                ""
            );
            _takeRemoved(deltaA, tokenA);
        }

        // Remove TeamB pool liquidity
        if (liquidityB > 0) {
            (BalanceDelta deltaB,) = poolManager.modifyLiquidity(
                poolKeyB,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: TICK_LOWER,
                    tickUpper: TICK_UPPER,
                    liquidityDelta: -int256(uint256(liquidityB)),
                    salt: bytes32(0)
                }),
                ""
            );
            _takeRemoved(deltaB, tokenB);
        }
    }

    // ─────────────────────── internal: settle helpers ────────────────────────

    function _settleAdd(BalanceDelta delta, Currency tokenCurrency) internal {
        int256 a0 = delta.amount0();
        int256 a1 = delta.amount1();

        if (a0 < 0) {
            poolManager.settle{value: uint256(-a0)}();
        }
        if (a1 < 0) {
            uint256 tokenAmt = uint256(-a1);
            poolManager.sync(tokenCurrency);
            IERC20(Currency.unwrap(tokenCurrency)).transfer(address(poolManager), tokenAmt);
            poolManager.settle();
        }
    }

    function _takeRemoved(BalanceDelta delta, OutcomeToken token) internal {
        int256 a0 = delta.amount0();
        int256 a1 = delta.amount1();

        if (a0 > 0) {
            poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), uint256(a0));
        }
        if (a1 > 0) {
            uint256 tokensBack = uint256(a1);
            poolManager.take(Currency.wrap(address(token)), address(this), tokensBack);
            token.burn(address(this), tokensBack);
        }
    }

    // ─────────────────────── internal: settlement ────────────────────────────

    function _executeSettlement(uint8 _winner) internal {
        settled = true;
        winner = _winner;

        // Remove all liquidity from both pools, collect ETH
        poolManager.unlock(abi.encode(ACT_REMOVE, bytes("")));

        // 1% settlement fee to marketingWallet
        uint256 settlementFee = address(this).balance / 100;
        if (settlementFee > 0) {
            (bool ok,) = payable(marketingWallet).call{value: settlementFee}("");
            require(ok, "Settlement fee failed");
        }

        totalSettledETH = address(this).balance;

        // Snapshot winner supply AFTER LP tokens are burned (only user holdings remain)
        OutcomeToken winnerToken = _winner == 1 ? tokenA : tokenB;
        settledWinnerSupply = winnerToken.totalSupply();

        emit Settled(_winner, totalSettledETH);
    }

    // ─────────────────────── internal: init ──────────────────────────────────

    function _seedLiquidity(uint256 totalEth) internal {
        uint256 ethA = totalEth / 2;
        uint256 ethB = totalEth - ethA;

        tokenA.mint(address(this), ethA);
        tokenB.mint(address(this), ethB);

        poolManager.unlock(
            abi.encode(ACT_INIT, abi.encode(InitParams({
                ethA: ethA,
                tokenMintA: ethA,
                ethB: ethB,
                tokenMintB: ethB
            })))
        );
    }

    function _computeLiquidity(uint256 ethAmount, uint256 tokenAmount) internal pure returns (uint128) {
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(TICK_UPPER);
        return LiquidityAmounts.getLiquidityForAmounts(
            INITIAL_SQRT_PRICE,
            sqrtPriceLower,
            sqrtPriceUpper,
            ethAmount,
            tokenAmount
        );
    }

    // ─────────────────────── internal: utils ─────────────────────────────────

    function _toSymbol(string memory name) internal pure returns (string memory) {
        bytes memory b = bytes(name);
        bytes memory sym = new bytes(b.length > 4 ? 4 : b.length);
        for (uint256 i = 0; i < sym.length; i++) {
            uint8 c = uint8(b[i]);
            // uppercase
            if (c >= 97 && c <= 122) c -= 32;
            sym[i] = bytes1(c);
        }
        return string(sym);
    }

    function _uintToStr(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 tmp = v;
        uint256 len;
        while (tmp != 0) { len++; tmp /= 10; }
        bytes memory b = new bytes(len);
        while (v != 0) { b[--len] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(b);
    }

    receive() external payable {}
}
