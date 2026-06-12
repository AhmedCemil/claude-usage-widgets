<div align="right"><a href="README.md">🇬🇧 English</a></div>

# claude-usage-widgets

**Windows 10/11** için, Claude'da ne kadar boş alanınız kaldığını bir bakışta gösteren üç
küçük, her zaman üstte masaüstü widget'ı — **sıfır kurulumla**.

**Olduğu gibi çalışır — Python yok, Node yok, pip yok, kurulacak hiçbir şey yok.** Çift tıkla
ve başla: widget'lar yalnızca Windows ile gelenleri kullanır (.NET WinForms + `curl.exe`).

**5 saat** &nbsp;·&nbsp; **Bağlam** &nbsp;·&nbsp; **Birleşik**

![5 saat widget'ı](images/screenshot-5h.png)

![bağlam widget'ı](images/screenshot-context.png)

![birleşik widget](images/screenshot-combined.png)

<sub>Birini seçin. Üstte: 5 saatlik limit (isteğe bağlı **7 günlük** satır gösterilmiş).
Ortada: oturum başına bağlam %'si. Altta: ikisi bir arada. (Anonim örnek veri.)</sub>

| Widget | Başlatma | Gösterir | `.env` gerekir mi? |
|--------|----------|----------|--------------------|
| **5 saat** | `widgets/5h/cuw.bat` | Paylaşılan **5 saatlik** limit % **ve 7 günlük (haftalık) limit** | Evet |
| **Bağlam** | `widgets/context/ctw.bat` | Oturum başına **bağlam penceresi %** (her oturumun 1M penceresi ne kadar dolu) | Hayır |
| **Birleşik** | `widgets/combined/ccw.bat` | Yukarıdakilerin ikisi tek pencerede | Evet |

Üçünden **birini** çalıştırın — her birinin kendi tek-örnek kilidi vardır, üst üste binmezler
ama ekranda çakışırlar. Çoğu kişi **Birleşik**'i (`widgets/combined/ccw.bat`) ister.


---

## Bu widget'ların izlediği iki "duvar"

Claude'un birbirinden ayrı limitleri vardır; bu widget'lar onları gösterir:

1. **5 saatlik limit** — paylaşılan, hesap geneli kullanım havuzu (`5h 42% (1h58m)`). %100'e
   ulaşınca sıfırlanana kadar duraklatılırsınız. Widget bunu claude.ai'den çeker.
2. **7 günlük (haftalık) limit** — daha uzun, yuvarlanan üst sınır (`7d 38% (4d 6h)`), 5 saat
   ve birleşik widget'larda **7 günü göster** ile gösterilir. Bazı hesaplarda haftalık limit
   yoktur; onlarda satır `7d n/a` görünür.
3. **Bağlam penceresi** — *her bir oturumun* 1M token'lık bağlamının ne kadar dolu olduğu
   (`Dev: 18% Access Claude chat… 180k * 2m`). Dolunca o oturum bozulur / `/compact` gerekir.
   Widget bunu doğrudan diskteki oturum dökümünden okur.

---

## Bağlam sayısı nasıl çalışır (ve neden güvenli)

Bağlam widget'ı, Claude Code'un her oturumun `.jsonl` dökümüne **zaten yazdığı gerçek token
kullanımını** okur (her asistan turunda yazılan `usage` bloğu:
`input + cache_creation + cache_read` = o turun taşıdığı gerçek bağlam — tahmin değil, API'nin
gerçek tokenizer sayısı).

Bunu her dökümün yalnızca **son 64 KB**'ını okuyarak yapar (tüm dosyayı değil, bir byte konumu
aramasıyla), bu yüzden megabaytlarca büyük dosyalarda bile anlıktır. En önemlisi:

> **Bağlam widget'ı asla `claude` çalıştırmaz, oturum çatallamaz, hiçbir şey başlatmaz.**
> Yalnızca yerel dosyaları okur. Yani 5 saatlik havuzunuzdan hiç harcamaz ve donmaz.

Oturum **başlıkları** (gerçek `/resume` seçici adları) **arka planda tembel** yüklenir —
pencere anında kısa kimliklerle çizilir, sonra başlıklar dolar (~200 ms). Hiçbir şey bloklamaz.

> **`/compact` uyarısı:** bir sıkıştırmadan hemen sonra, oturum dökümü birkaç yeni tur gelene
> kadar hâlâ *sıkıştırma öncesi* zirveyle biter. Sayı, oturum devam ettikçe kendini düzeltir.
> (Bağlam okuması bu yüzden tamamen yereldir — "düzeltmek" için bir şey başlatmaz.)

---

## Kurulum

### 1. Kimlik bilgileri (yalnızca 5 saat / birleşik widget için)

[`claude_usage.env.example`](claude_usage.env.example) dosyasını
`%USERPROFILE%\.claude\claude_usage.env` konumuna kopyalayın ve oturum açılmış claude.ai
tarayıcınızdan üç değeri doldurun:

- `SESSION_KEY` — `sessionKey` çerezi (`sk-ant-sid01-…`)
- `ORG_ID` — kuruluş UUID'niz (herhangi bir `/api/organizations/<ID>/…` isteğinden)
- `DEVICE_ID` — `anthropic-device-id` çerezi (isteğe bağlı ama önerilir)

`.env.example` adım adım DevTools talimatları içerir. **Bağlam widget'ı (`ctw.bat`) bunların
hiçbirine ihtiyaç duymaz** — yalnızca yerel dökümleri okur.

> Neden PowerShell'in `Invoke-RestMethod`'u değil de `curl`? `claude.ai` Cloudflare arkasında;
> PowerShell'in .NET TLS yığınını 403 ile sınar ama `curl.exe`'ı geçirir.

### 2. Çalıştırın

`widgets/` altında istediğiniz widget'ın başlatıcısına çift tıklayın:
**`widgets/combined/ccw.bat`** (birleşik), `widgets/5h/cuw.bat` (5 saat) veya
`widgets/context/ctw.bat` (bağlam). Sağ üstte belirir. (Her widget'ın `.bat`, `.vbs` ve `.ps1`
dosyaları tek klasörde birlikte durur — taşırsanız üçlüyü birlikte tutun.)

### 3. İsteğe bağlı — açılışta çalıştır

<kbd>Win</kbd>+<kbd>R</kbd> → `shell:startup` → seçtiğiniz `.bat` dosyasının kısayolunu
o klasöre bırakın.

---

## Widget'ları kullanma

- Taşımak için sol fare tuşuyla **sürükleyin** (konum her widget için kaydedilir).
- **Sol tık** (5 saat / birleşik): sıfırlanma gösterimini kalan (`1h58m`) ile tam saat
  (`@14:30`) arasında değiştirir.
- Menü için **sağ tık**: Şimdi yenile · 7 günü göster (5 saat/birleşik) · Konumu kilitle ·
  Açıklama / Yardım · Çıkış.

### Bağlam satırlarını okuma

```
● Dev: 18% Access Claude chat conte…  180k * 2m
○ mm:  48% Reorganize Python projec…  476k ~ 2h
```

- **●** son 60 sn içinde dokunulmuş (aktif) · **○** boşta ama yakında dokunulmuş
- **büyük %** = o oturumun 1M penceresinin ne kadar dolu olduğu (renk kademeli)
- `180k` = kullanılan gerçek token · `*` aktif / `~` boşta · `2m` = son yazılmadan beri
- `reading` = dökümünün kuyruğunda henüz usage bloğu olmayan yepyeni bir oturum

**Renk kademeleri** (hem 5 saat hem bağlam %'si): doldukça yeşil → sarı → kehribar → kırmızı.
Bağlam kademeleri sıkıştırma eşikleridir: yeşil `<%30` · sarı `<%50` · kehribar `<%60` ·
kırmızı `≥%60`.

---

## Yedek korumalar

- **`(RL)` = hız sınırlı.** 5 saat API'si HTTP 403 dönerse, widget **son iyi sayıları** tutar,
  `(RL)` ekler ve 60 sn sonra yeniden dener — asla boşalmaz.
- **`401 refresh .env`** — oturumunuz doldu; kimlik bilgilerini yenileyin.
- **`offline` / `http NNN`** — ağ/sunucu sorunu; varsa son iyi değeri korur.
- **Thread dışı çekme** — 5 saat curl çağrısı arayüz thread'inin dışında çalışır, bu yüzden
  yavaş ağda bile widget donmaz.

---

## "Bu sistemde betik çalıştırma devre dışı"

Windows `.ps1` dosyalarını varsayılan olarak engeller — **hiçbir sistem ayarını değiştirmenize
gerek yok.** `.vbs`/`.bat` başlatıcıları PowerShell'i yalnızca **o tek başlatma** için
`-ExecutionPolicy Bypass` ile çağırır (yönetici gerektirmez, kalıcı bir şey değiştirmez). Her
zaman `.ps1` ile değil, **`.bat`** ile başlatın.

---

## Yerleşim

```
claude-usage-widgets/
├─ widgets/
│  ├─ 5h/        usage-widget.ps1   + cuw.bat / cuw.vbs
│  ├─ context/   context-widget.ps1 + ctw.bat / ctw.vbs
│  └─ combined/  combined-widget.ps1 + ccw.bat / ccw.vbs
├─ images/       ekran görüntüleri
├─ docs/         README_5h_EN.md / README_5h_TR.md  (5 saat ayrıntılı)
├─ claude_usage.env.example   kimlik şablonu (kopyala → ~/.claude/claude_usage.env)
├─ README.md / README_TR.md   bu dosya (EN / TR)
└─ LICENSE
```

Her widget kendi klasöründe **bağımsızdır** (`.bat`, kardeş `.vbs`'i başlatır, o da kardeş
`.ps1`'i başlatır). Bir klasörü herhangi bir yere taşıyın, yine çalışır — yeter ki üç dosyayı
birlikte tutun.

Her widget `powershell.exe` olarak çalışır (ayrı bir `.exe` yok). Kapatmak için sağ tık →
**Çıkış**, ya da yalnızca onu zorla kapatmak için komut satırını eşleştirin
(`*combined-widget.ps1*` vb.). Bir `.bat`'ı iki kez başlatmak hiçbir şey yapmaz — adlandırılmış
bir mutex tek örneği korur.

---

## Gizlilik ve güvenlik

- `SESSION_KEY` **canlı bir oturum anahtarıdır** — doldurulmuş `.env`'i bir parola gibi
  koruyun. Dahil edilen [`.gitignore`](.gitignore) `*.env`'i (ve kullanıcıya özel
  yapılandırma/önbelleği) git'in dışında tutar; yalnızca `.example` izlenir.
- 5 saat okuması dışında hiçbir yere bir şey gönderilmez (`claude.ai`'ye). Bağlam widget'ı
  **hiç ağ çağrısı yapmaz** — yalnızca yerel dökümlerinizi okur.

---

## Lisans

MIT — bkz. `LICENSE`.
