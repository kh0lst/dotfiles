# yt-dlp installation:
# uv tool install yt-dlp[default,curl-cffi,secretstorage,deno]
#
# for js-challeng to work (see https://github.com/yt-dlp/yt-dlp/wiki/EJS):
# npm install -g deno
# or
# cargo install deno --locked

# yt-dlp \
uvx yt-dlp[default,curl-cffi,secretstorage,deno] \
  -x --audio-format mp3 \
  --embed-metadata \
  --embed-thumbnail \
  --add-metadata \
  --metadata-from-title "%(artist)s - %(title)s" \
  -o "%(artist)s - %(title)s.%(ext)s" \
  --cookies-from-browser "brave+gnomekeyring:~/.config/BraveSoftware/Brave-Origin" \
  "$1"
