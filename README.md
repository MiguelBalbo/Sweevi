<p align="center">
  <img src="Branding/sweevi-icon.png" width="128" height="128" alt="Ícone do Sweevi">
</p>

<h1 align="center">Sweevi</h1>

App macOS bem simples (SwiftUI) para baixar vídeos com o [yt-dlp](https://github.com/yt-dlp/yt-dlp) de qualquer [site suportado](https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md).

1. Cole o link e clique em **Buscar**.
2. Escolha uma opção: melhor qualidade, uma resolução específica, somente áudio (MP3) ou qualquer formato bruto.
3. Clique em **Baixar**. O arquivo vai para a pasta escolhida (padrão: Downloads).

## Requisitos

- macOS 14 ou mais recente
- yt-dlp e ffmpeg (o ffmpeg junta vídeo + áudio e converte para MP3):

```bash
brew install yt-dlp ffmpeg
```

## Rodar

```bash
swift run
```

Ou abra o `Package.swift` no Xcode e aperte ⌘R.

## Gerar o .app

```bash
./build-app.sh
```

Gera `Sweevi.app` (já com o ícone) nesta pasta; arraste para Aplicativos se quiser.

## Logo

O símbolo é o play girado para baixo: ele vira a seta de download e cai no cursor de uma barra de progresso. Os arquivos ficam em [`Branding/`](Branding):

| Arquivo | Uso |
|---|---|
| `sweevi-symbol.svg` | Símbolo colorido (violeta `#6A3DF5`) |
| `sweevi-symbol-black.svg` / `-white.svg` | Versões em uma cor |
| `sweevi-symbol-small.svg` | Versão reforçada para tamanhos pequenos (≤ 32 px) |
| `sweevi-icon.svg` / `.png` | Ícone do app |
| `AppIcon.icns` | Ícone usado pelo `build-app.sh` |

> Dica: sites mudam com frequência. Se um download parar de funcionar, atualize o yt-dlp com `brew upgrade yt-dlp`.
