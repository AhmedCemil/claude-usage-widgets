# Claude Kullanım Widget'ı (Python'suz)

**Claude 5 saatlik limit %**'nizi (isteğe bağlı olarak **7 günlük** limiti de) gösteren,
her zaman üstte küçük bir masaüstü widget'ı. Windows 10/11 için **sıfır kurulumla** yapıldı —
yalnızca Windows ile gelen şeyleri kullanır:

- **.NET WinForms** — yüzen pencere
- **curl.exe** — HTTPS çağrısı (2018'den beri Win10/11'de yerleşik)

> Neden PowerShell'in `Invoke-RestMethod`'u değil de curl? `claude.ai` Cloudflare arkasında,
> PowerShell'in .NET TLS yığınını 403 ile sınar ama `curl.exe`'ı geçirir. curl, ek bağımlılık
> olmadan güvenilir yoldur.

## Dosyalar

| Dosya | Ne yapar |
|-------|----------|
| `usage-widget.ps1` | Widget'ın kendisi (arayüz + veri çekme). |
| `cuw.vbs` | Widget'ı **gizli** başlatır — konsol penceresi parlaması yok. |
| `cuw.bat` | Çift tık / PATH giriş noktası. `cuw.vbs`'i çağırır. |

## Kurulum

1. **Kimlik bilgileri** — widget, setin geri kalanıyla aynı `.env`'i okur:
   `SESSION_KEY`, `DEVICE_ID`, `ORG_ID` değerlerini `~/.claude/claude_usage.env` içine koyun
   (`claude_usage.env.example`'dan kopyalayın). Anahtar yoksa widget `5h: -- (no .env)` gösterir.
2. **Çalıştırın** — `cuw.bat` dosyasına çift tıklayın (veya `cuw.vbs`'i çalıştırın). Widget sağ üstte belirir.
3. **İsteğe bağlı — açılışta çalıştır:** <kbd>Win</kbd>+<kbd>R</kbd> tuşlayın, `shell:startup` yazın
   ve o klasöre `cuw.bat` (veya `cuw.vbs`) kısayolu bırakın.

## Kullanımı

- Yeniden konumlandırmak için sol fare tuşuyla **sürükleyin** (başlatmalar arası hatırlanır).
- Sıfırlanma süresini **kalan** `5h: 47% (1h58m)` ile **tam saat** `5h: 47% @14:30` arasında
  değiştirmek için widget'a **tıklayın**.
- Menü için **sağ tık**:
  - **Refresh** — şimdi çek.
  - **Show 7d** — 7 günlük limit satırını aç/kapat (aşağıya bakın).
  - **Lock position** — kazara sürüklemeyi durdur.
  - **Quit** — çıkış.

İki satır şunu gösterir:
```
5h: 47% (1h58m)     ← limit % + ne zaman sıfırlanır (yüke göre renkli)
@ 14:02:13          ← en son ne zaman kontrol edildi
```

Konum, 7g aç/kapat ve zaman-biçimi seçimi `~/.claude/.usage_widget.cfg` içinde kalıcıdır.

## Güvenlik mekanizmaları (limit & hatalar)

- **`(RL)` = limitlendi (rate-limited).** Kullanım API'si **HTTP 403** (Cloudflare/limit)
  döndürürse, widget **boş kalmaz** — **son iyi değerleri** göstermeye devam eder ve saat
  satırına `(RL)` ekler (`@ 14:02:13 (RL)`), sonra 60 sn sonra tekrar dener. Bu, orijinal
  Python widget'ını yansıtır.
- **`401 refresh .env`** — oturumunuz doldu; `~/.claude/claude_usage.env` içindeki kimlik
  bilgilerini yenileyin.
- **`offline` / `http NNN`** — ağ veya sunucu sorunu; varsa son iyi değeri korur, yoksa kısa
  hatayı saat satırında gösterir.

## 5s ↔ 5s + 7g

**7 günlük (haftalık) limit satırı varsayılan kapalıdır**, çünkü bazı hesaplar haftalık veri
döndürmez (alan null gelir) — onlar için sadece `7d: n/a` görünürdü.

- **"Show 7d"** sağ tık öğesiyle canlı açın — kod düzenlemesi yok.
- Ya da açılışta açık başlamak için `usage-widget.ps1`'in başındaki `$ShowWeeklyDefault = $true` yapın.
- Hesabınızın haftalık limiti yoksa satır `7d: n/a` gösterir ve 5s satırı çalışmaya devam eder.

## "Bu sistemde betik çalıştırma devre dışı" — bunu okuyun

Windows, `.ps1` dosyalarının doğrudan çalışmasını varsayılan engeller (ExecutionPolicy `Restricted`).
**Hiçbir sistem ayarını değiştirmenize gerek yok** — başlatıcılar bunu halleder:

- `cuw.vbs` / `cuw.bat`, PowerShell'i `-ExecutionPolicy Bypass` ile çağırır; bu yalnızca
  **o tek başlatma** için geçerlidir. Yönetici hakkı gerektirmez, kalıcı bir şey değiştirmez.

Yani widget'ı her zaman **`cuw.bat` / `cuw.vbs`** ile başlatın, `.ps1`'e çift tıklayarak değil.

`.ps1` dosyalarını doğrudan çalıştırmak *isterseniz* (isteğe bağlı, sizin tercihiniz):
```powershell
# kullanıcı başına, yönetici yok — yerel betiklere + imzalı uzak betiklere izin verir
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

## Renkler

5s % değeri, yükü bir bakışta okuyabilmeniz için renk kodludur:

| Aralık | Renk |
|--------|------|
| < %50 | yeşil |
| %50–70 | sarı |
| %70–90 | turuncu |
| ≥ %90 | kırmızı |

## Süreç adı / kapatma

Widget **`powershell.exe`** olarak çalışır (Görev Yöneticisi'nde "Windows PowerShell" görünür) —
ayrı bir `.exe` yoktur. Normalde sadece **sağ tık → Quit**.

*Yalnızca bu widget'ı* bulmak veya zorla kapatmak için (diğer PowerShell pencerelerinize
dokunmadan), komut satırına göre eşleştirin:

```powershell
# bul
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*usage-widget.ps1*' }

# durdur
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*usage-widget.ps1*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

**Tek örnek:** widget çalışırken `cuw.bat`'ı tekrar başlatmak **hiçbir şey yapmaz**
(adlandırılmış bir mutex, ikinci kopyanın sessizce çıkmasını sağlar); yani yanlışlıkla iki tane açmazsınız.
