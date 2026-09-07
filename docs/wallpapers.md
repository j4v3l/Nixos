# Crimson wallpapers

Crimson is a shared palette inspired by these two images. Neither image is
included in the repository or made the default wallpaper.

| Image | Source | Attribution available on the source page |
| --- | --- | --- |
| Darth Vader, black and crimson | [Wallhaven 13pgxw](https://wallhaven.cc/w/13pgxw) | Uploaded by Mazachi; original artist not identified there |
| Anime illustration, pink and charcoal | [Wallhaven 3q6m6y](https://wallhaven.cc/w/3q6m6y) | Hiroki Ree; [artist profile](https://pixiv.net/users/17341759) |

The artists retain their rights. Source-page availability is not a license to
redistribute the artwork. The optional Nix fetches use the original image URLs
and SHA-256 hashes recorded in `lib/wallpapers.json`.

Set `features.wallpapers` to `true` in the host JSON and rebuild. Home Manager
links both images into `~/Wallpapers`; the picker follows those symlinks.
Selecting an image writes the existing wallpaper state, which activation does
not overwrite.

Wallhaven may reject automated downloads with HTTP 403. If that happens,
download the original PNG through its source page in a browser, preserving the
filename, then import that exact file before rebuilding:

```bash
nix hash file ~/Downloads/wallhaven-13pgxw.png
nix-store --add-fixed sha256 ~/Downloads/wallhaven-13pgxw.png
```

Compare the reported SRI hash with `lib/wallpapers.json`. Repeat for
`wallhaven-3q6m6y.png`. Resized previews have different hashes. A failed optional
fetch does not affect hosts with the wallpaper bundle disabled.
