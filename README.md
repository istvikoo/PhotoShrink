# PhotoShrink

A small native macOS app that shrinks photos to a given number of **megapixels** and saves them as **HEIC**, JPEG or the original format.

[Українською ↓](#українською)

## Features

- Set the target size in megapixels (presets 2 / 5 / 8 / 12 / 24 or any value)
- Save as HEIC, JPEG or keep the original format, with adjustable quality
- Drag & drop photos or whole folders (also onto the Dock icon)
- Keeps EXIF metadata (date, camera, GPS) and applies rotation correctly
- Never upscales and never overwrites originals: results go to a `Compressed` folder or a folder you pick
- English and Ukrainian interface
- Updates itself from GitHub Releases
- Universal app (Apple Silicon + Intel), macOS 13 or later, no dependencies, uses only Apple's ImageIO

## Install

1. Download `PhotoShrink-x.y.z.zip` from [Releases](../../releases/latest) and unzip it.
2. Move `PhotoShrink.app` to **Applications**. Auto-update only works from there.
3. The app isn't notarized by Apple, so on first launch macOS will block it.
   Open **System Settings → Privacy & Security** and click **Open Anyway**, or run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/PhotoShrink.app
   ```

## Build from source

Needs only the Xcode Command Line Tools (`xcode-select --install`):

```bash
./build.sh            # → build/PhotoShrink.app
```

## Publish a release

```bash
./release.sh 1.1.0
```

This bumps the version, builds, zips, tags, pushes and creates a GitHub release using `gh`.
Installed copies see the new version on their next launch (they check at most every 6 hours) or via **Check for Updates…**.

## License

[MIT](LICENSE)

---

## Українською

Маленька програма для macOS, яка зменшує фото до заданої кількості **мегапікселів** і зберігає їх у **HEIC**, JPEG або в початковому форматі.

- Розмір у мегапікселях (кнопки 2 / 5 / 8 / 12 / 24 або будь-яке число)
- HEIC / JPEG / як оригінал, регулювання якості
- Перетягування фото або цілих папок
- Зберігає метадані (дата, камера, GPS)
- Не збільшує фото й не перезаписує оригінали
- Українська та англійська мови
- Оновлюється сама з GitHub Releases

**Встановлення:** завантажте zip з [Releases](../../releases/latest), перемістіть `PhotoShrink.app` у «Програми».
Під час першого запуску macOS заблокує програму, бо вона не нотаризована Apple. Відкрийте **Системні параметри → Приватність і безпека** і натисніть **Все одно відкрити**.
