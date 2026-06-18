# Yubii Cup — Gerçek Zamanlı Trading Vizyonu

## Problem
Kripto yatırımcısı 2-3 saat beklemez.
- Bahis yap → kickoff bekle → maç izle → settlement → redeem = çok uzun
- Genç kripto kullanıcısı chart'ta pump/dump ister
- "Erken aldım, pump yedi, sattım" hissi lazım

## Çözüm: Prediction Market + Spot Trading Hibrit

### Faz 1 — İkincil Piyasa (Outcome Token Trading)
- ySwitzerlandWin token → İsviçre gol atınca pump
- Maç bitmeden token satılabilir, kâr realize edilir
- Outcome token'lar ERC20 → Uniswap'ta ikincil havuz

### Faz 2 — Canlı Maç İçi Fee Sistemi
- Maç skoru + dakikaya göre değişen fee curve
- Oracle (Chainlink/API3) → canlı skor on-chain
- beforeSwap → maç istatistiklerini okur

### Faz 3 — Chart Deneyimi
- TradingView widget → yubii.eth.limo
- Canlı fiyat feed → The Odds API + on-chain pool price
- "X dakikada X% kazandım" paylaşım butonu

### Faz 4 — Hızlı Formatlar
- 5 dakikalık micro-market'ler
- Halftime market'leri
- Anlık prop'lar

## Öncelik
1. ✅ Mainnet deploy
2. ✅ Kilitlenme fix
3. 🔲 İkincil havuzlar
4. 🔲 Canlı skor oracle
5. 🔲 Chart UI
6. 🔲 Micro-market'ler
