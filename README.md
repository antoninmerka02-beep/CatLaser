# CatLaser – laserová kořist pro kočku (Tesla Smart Laser Dot)

## v0.2 – záložka Hra

- živý náhled kamery (přepínač Širokoúhlý 0,5× / Standardní 1×, každý má vlastní kalibraci)
- automatická kalibrace: laser projede 16 bodů, kamera najde tečku (rozdíl snímků laser zap/vyp),
  spočítá se homografie podlahy kamera → laser a dosažitelná oblast (modrá čárkovaná)
- ohraničení hřiště („digital fence“): klepnutím do obrazu přidáváš rohy, tažením je posouváš;
  tečka nikdy nevyjede ze žluté oblasti (ukládá se v souřadnicích laseru, platí pro oba objektivy)
- sledování kočky přes Vision (VNRecognizeAnimalsRequest, ~12×/s), pozice = spodní okraj rámečku (tlapky)
- logika kořisti: láká → utíká (rychlost podle blízkosti kočky, uhýbá od okrajů) → zamrzne / schová se
  → po ~N útěcích se nechá chytit → na konci hry se nechá chytit a zhasne
- pojistky (lze vypnout): „Nesvítit na kočku“ a „Vypnout laser, když kočka zmizí“
- nastavení: intenzita, délka hry, jak často se nechá chytit, citlivost detekce

## v0.1 – záložka Test

Testovací obrazovka, která se k laseru (Tuya BLE, model TSL-PC-PTY010) připojí napřímo,
bez Smart Life / Tesla aplikace, a ovládá ho:

- zapnutí / vypnutí laseru (DP 105)
- vestavěné režimy Stop / Malý / Střední / Velký (DP 104)
- ruční pohyb tečky po ploše 0–400 × 0–400 (DP 102)
- testovací pohyby (kruh, tam a zpět, skoky) pro posouzení plynulosti a zpoždění
- měření odezvy (čas od odeslání pohybu po potvrzení od laseru)
- log komunikace (lze zkopírovat)

DP 106 (tovární reset MCU) aplikace nikdy neposílá.

## Build

Repo obsahuje workflow `.github/workflows/build.yml`. Po každém pushi GitHub Actions
(macOS runner) vygeneruje projekt přes XcodeGen, sestaví nepodepsanou aplikaci a nahraje
`CatLaser.ipa` jako artefakt (Actions → poslední běh → Artifacts → CatLaser-ipa).
IPA se nainstaluje přes Sideloadly stejně jako NaviTest.

## První spuštění

1. Zavři Smart Life / Tesla aplikaci (laser zvládne jen jedno spojení).
2. V aplikaci otevři Nastavení (ozubené kolo), zkopíruj celou odpověď z Tuya API Exploreru
   (Query Device Details) a klepni na „Vložit JSON ze schránky“. Vyplní se Device ID, Local key a UUID.
3. Klepni na Připojit. V logu by mělo být: DEVICE_INFO → PAIR → „✅ Spárováno“.
4. Zapni laser a táhni prstem po ploše.

Údaje se ukládají jen v telefonu, nejsou v kódu ani v repu.

## Protokol

`Sources/TuyaBLE.swift` je port open-source implementace
[ha_tuya_ble](https://github.com/PlusPlus-ua/ha_tuya_ble):
login key = MD5(prvních 6 znaků local_key), session key = MD5(6 znaků local_key + srand z DEVICE_INFO),
AES-128-CBC, CRC16/MODBUS, fragmentace po 20 B na charakteristiku 2B11, odpovědi z 2B10.
