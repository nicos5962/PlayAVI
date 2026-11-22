# PlayAVI

Lyrion Music Server (LMS) plugin: **AVI**. Plays the audio track of AVI video files.

## Features

- File types: `avi`
- Discogs release id (tag such as `DISCOGS_RELEASE_ID`) is used as the album id, so different releases of the same album / artist are not merged into one album
- Scanner-safe registration (`Register.pm`): the tag handler is registered both in the server and in the scanner (`Importer.pm`), without any web / UI dependency
- Tags (title, artist, album, ...) and audio properties are read with `ffprobe`; the audio stream is decoded by `ffmpeg`
- Transcoding through `ffmpeg` (and `lame` for MP3 output) via `custom-convert.conf`; FLAC is preferred over PCM

## Requirements

- Lyrion Music Server 7.7 or newer (developed on 9.1.1)
- `ffmpeg`, `ffprobe`, `lame` (MP3 output) available to the server

## Installation

Copy the `PlayAVI` folder into the `Plugins` directory of the server cache (for example `/config/cache/Plugins`), then restart Lyrion and rescan the library.

## Files

| File | Purpose |
| --- | --- |
| `install.xml` | Plugin manifest |
| `Plugin.pm` | Server plugin, registers the handler |
| `Importer.pm` | Scanner entry point |
| `Register.pm` | Registers the tag handler (shared by server and scanner) |
| `Formats/` | Tag handler for the file type |
| `custom-types.conf` | File suffix / MIME type |
| `custom-convert.conf` | Transcoding rules |
| `strings.txt` | Text strings |

## Version

1.1

## Author

nicos

## Changelog

### 1.1
- Rip folders with a concert date, `(1995-10-15) Place`, are recognised like `(2003) Album`: the artist comes from the folder above, the year from the date, and the date goes into the comment.
- A title that is only the name of an audio stream (`Stereo`, `Surround 5.1`, `Dolby Digital 5.1`, ...) is no longer used as the track title; the title then comes from the file name.

### 1.0
- First release.
