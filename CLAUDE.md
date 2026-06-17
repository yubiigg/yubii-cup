# Yubii Cup — On-chain Sports Prediction Protocol

## Özet
Uniswap V4 üzerinde PvP spor tahmin protokolü.
Her maç = iki outcome token (yUSA, yMEX).
Kazanan tüm pool ETH'ini alır. Built on Ethereum.

## Stack
- Contracts: Solidity 0.8.30, Foundry, Uniswap V4
- Frontend: Next.js 14 (static export), wagmi, viem, RainbowKit
- IPFS: Pinata
- Oracle: UMA Optimistic Oracle V3
- Chain: Ethereum (Sepolia testnet → Mainnet)

## Kontrat Adresleri (Sepolia - Latest)
YubiiToken:   0xAd8f38A0940351f0602CBbD4Ab39B4F06C038AaF
YubiiFactory: 0x38Df9f316abb91163Fbfd6eaB048DC357BA384A8
USA vs MEX:   0xd7E7fc8F64de9938cc1af4BFe2Ed75117b1a0925
ENG vs FRA:   0x74c7Bd018296BC6bc719D1c73d31f4A6b3a5353A
BRA vs ARG:   0x7550EBcaf781bb5eb339f663142988De4d1b659e
GER vs ESP:   0xF21aD4Bf258129216FFc62EE36242DdA40849Bb1

## Önemli Adresler
Deployer:          0x83633E8bEd0ad8D741f41aE4e8a1248E611cb7F9
Marketing Wallet:  0xfCFA09B1Bc297F7B61401FbfBf76865fE9b12CB0
Owner (mainnet):   0xF025Ab8420743004eB5D47CC84E2C12e1b797F47

## Mainnet Adresleri
PoolManager: 0x000000000004444c5dc75cB358380D2e3dE08A90
UMA OO v3:   0x88Ad27C41AD06f01153E7Cd9b10cBEdF4616f4d5
POSM:        0xbd216513d74c8cf14cf4747e6aaa6420ff64ee9e

## Tamamlanan Özellikler
- [x] MatchMarket — buy/sell/settle/redeem
- [x] YubiiFactory — createMatch, freezeLeague, thawLeague
- [x] Launch tax (20% → reduceTax → %0.3 kalıcı)
- [x] Max buy limit + removeLimits()
- [x] EWMA Dynamic fee (SOFT/BALANCED/AGGRESSIVE)
- [x] Emergency controls (holdMatch, reclaimETH, reclaimToken)
- [x] breakPinky() — kickoff öncesi ETH geri çekme
- [x] Settlement fee (%1 marketing wallet)
- [x] 88/88 unit test
- [x] Sepolia deploy + verify (14/14)
- [x] Full lifecycle test on Sepolia

## Yapılacaklar
- [ ] removeLimits() test on Sepolia
- [ ] reduceTax() test on Sepolia
- [ ] Web sitesi (Next.js static)
- [ ] Pinata IPFS deploy
- [ ] ENS content hash güncelle
- [ ] Mainnet deploy
- [ ] yubii.eth.limo canlı

## Fee Stratejisi
Launch: 20% tax, 0.01 ETH max buy
~30 dk: removeLimits()
~60 dk: reduceTax(30, 30) → %0.3 kalıcı
Dynamic fee: BALANCED default (30-300 bps, EWMA)

## Maç Profil Stratejisi
Grup maçları: SOFT (30-100 bps)
Round of 32/16: BALANCED (30-300 bps)
Çeyrek/Yarı/Final: AGGRESSIVE (30-500 bps)

## GitHub
https://github.com/yubiigg/yubii-cup

## Çalışma Komutu
cd /Users/erkanakdeniz/shobu-cup
export NODE_TLS_REJECT_UNAUTHORIZED=0 && claude --dangerously-skip-permissions

## gstack

Web browsing: always use the `/browse` skill from gstack. Never use `mcp__claude-in-chrome__*` tools directly.

Available gstack skills:
- `/browse` — browser automation for web research and scraping
- `/cso` — chief strategy officer review
- `/review` — structured code review
- `/guard` — safety and security check

## Aktif Görev
[Her session başında buraya yaz]
