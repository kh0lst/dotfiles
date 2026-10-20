uvx yt-dlp[default,curl-cffi,secretstorage,deno] \
  --cookies-from-browser "brave+gnomekeyring:~/.config/BraveSoftware/Brave-Origin" \
  --download-sections "*$2" \
  --force-keyframes-at-cuts \
  $1
