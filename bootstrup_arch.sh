#!/bin/bash
(
set -euo pipefail

BW_PORT=8087
BW_HOST="127.0.0.1"
BW_BASE="http://$BW_HOST:$BW_PORT"
BW_LOG=/tmp/bw-serve.log

msg() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

ensure_pkgs() {
    local missing
    missing=$(pacman -T "$@") || true
    if [[ -n $missing ]]; then
        yay -S --needed --sudoloop --noconfirm --answerdiff None --answerclean None $missing
    fi
}

prompt_for_bw_password() {
    IFS= read -rsp 'Bitwarden password: ' BW_PASSWORD </dev/tty
    echo >&2
    export BW_PASSWORD
}

get_bw_session() {
    local -a cmd
    local attempt max=3

    if [[ $(bw status | jq -re '.status' 2>/dev/null) == "unauthenticated" ]]; then
        cmd=(bw login "$BW_EMAIL")
    else
        cmd=(bw unlock)
    fi

    for ((attempt = 1; attempt <= max; attempt++)); do
        BW_SESSION=
        IFS= read -r BW_SESSION < <("${cmd[@]}" --passwordenv BW_PASSWORD --raw) || true

        # +x - to expand BW_SESSION into x instead of real value (mask when set -x is set)
        if [[ -n ${BW_SESSION:+x} ]]; then
            export BW_SESSION
            return 0
        fi

        echo "Bitwarden login/unlock failed (attempt $attempt/$max)" >&2
        if ((attempt < max)); then
            prompt_for_bw_password
        fi
    done

    return 1
}

bw_cleanup() {
    kill "$BW_PID" 2>/dev/null || true
    wait "$BW_PID" 2>/dev/null || true
}

bw_get() { curl "$BW_BASE/object/$1/$2" 2>/dev/null | jq -re .data$([[ "$1" != item ]] && echo .data); }

deploy_bw_ssh_key() {
    install -d -m 700 ~/.ssh
    install <( bw_get item "$1" | jq -re '.sshKey.publicKey'  ) -m 600 "$HOME/.ssh/$2.pub"
    install <( bw_get item "$1" | jq -re '.sshKey.privateKey' ) -m 600 "$HOME/.ssh/$2"
}

ensure_mega_sync() {
    mkdir -p "$1"
    mega-ls "$2" >/dev/null 2>&1 || mega-mkdir -p "$2"
    if mega-sync | grep -Fq "$1"; then
        echo "= exists:  $1 -> $2"
    else
        mega-sync "$1" "$2"
        echo "+ created: $1 -> $2"
    fi
}

###############################################################################
# prompt for secrets
###############################################################################
sudo -v

# bw email
email_cache=${XDG_RUNTIME_DIR:-$HOME/.cache}/bw-setup-email

if [[ -z ${BW_EMAIL-} ]]; then
    cached_email=
    [[ -r $email_cache ]] && IFS= read -r cached_email < "$email_cache"
    IFS= read -r -e -i "$cached_email" -p 'Bitwarden email: ' BW_EMAIL </dev/tty
fi
[[ -n $BW_EMAIL ]] || { echo "Bitwarden email is required" >&2; exit 1; }

# bw pass
prompt_for_bw_password

time {
mkdir -p "${email_cache%/*}"
(umask 077; printf '%s\n' "$BW_EMAIL" > "$email_cache")

# ensure all required home directories present
mkdir -p ~/Pictures/wallpapers ~/Videos ~/Documents ~/Music

# ensure yay
if ! command -v yay >/dev/null 2>&1; then
    [[ -d /tmp/yay/.git ]] || git clone https://aur.archlinux.org/yay-bin.git /tmp/yay
    (cd /tmp/yay && makepkg)
    sudo pacman --noconfirm -U /tmp/yay/yay-bin*.pkg.tar.zst
    rm -rf /tmp/yay
    msg 'yay: installed'
else
    msg 'yay: already installed'
fi


###############################################################################
# bw setup & secrets deploys
###############################################################################
ensure_pkgs bitwarden-cli jq

if [[ $(bw config server) != 'https://pass.big-booty.pics' ]]; then
    bw logout >/dev/null 2>&1 || true
    bw config server pass.big-booty.pics
fi

get_bw_session || { echo "Could not get a Bitwarden session, giving up." >&2; exit 1; }

trap bw_cleanup EXIT
# just rout INT/TERM through EXIT so that bw_cleanup trap fires
trap 'exit 130' INT
trap 'exit 143' TERM

bw serve --hostname "$BW_HOST" --port "$BW_PORT" >"$BW_LOG" 2>&1 &
BW_PID=$!

for _ in $(seq 1 50); do
    curl -fsS "$BW_BASE/status" >/dev/null 2>&1 && break
    kill -0 "$BW_PID" 2>/dev/null || {
        echo "bw serve failed to start:" >&2; cat "$BW_LOG" >&2; exit 1; }
    sleep 0.2
done
echo 'bw sync resposne:' $(curl -fsSX POST "$BW_BASE/sync")
msg 'bw: synced';

deploy_bw_ssh_key 'ssh-rsa' 'id_rsa';
deploy_bw_ssh_key 'ssh-ed'  'id_ed25519';
msg 'bw: ssh keys deplyed';

bw_get username gpg | base64 -d | gpg --import --batch;
bw_get password gpg | base64 -d | gpg --import --batch;
bw_get item gpg | jq -re '.fields[0].value' | base64 -d | gpg --import-ownertrust --batch;
msg 'bw: gpg imported';


###############################################################################
# packages & dots installation
###############################################################################
PKGS_BASE=(
    base-devel starship mise uv cowsay fzf
    docker docker-buildx docker-compose
    tmux nvim tree-sitter-cli obs-studio
    telegram-desktop brave-origin-bin copyq
    ffmpeg vlc imagemagick qbittorrent

    # AUR stuff
    megacmd-bin hyprqt6engine dotter-rs-bin
)
ensure_pkgs "${PKGS_BASE[@]}"
msg 'yay: base packages installed'

# ensure my dots are cloned and up to date
if [[ -d "$HOME/.dotfiles/.git" ]]; then
    ( cd "$HOME/.dotfiles" && git pull)
else
    [[ -a  "$HOME/.dotfiles" ]] && mv "$HOME/.dotfiles" "$HOME/.dotfiles.$(date +%s).bak" || true
    GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new' git clone "git@github.com:kh0lst/dotfiles.git" "$HOME/.dotfiles"
fi

[[ -f "$HOME/.dotfiles/.dotter/local.toml" ]] || echo 'packages = ["default"]' > "$HOME/.dotfiles/.dotter/local.toml"

# TODO: figure out if we can somehow make a dotter backup config files
# if they are present instead of simply removing them
(cd "$HOME/.dotfiles" && dotter -f --noconfirm)
command -v hyprctl && hyprctl reload || true

mise up
for p in isort black gay yt-dlp; do
    command -v "$p" > /dev/null || mise x uv -- uv tool install "$p"
done
msg 'mise: done'

###############################################################################
# apps/tools setup
###############################################################################

# brave theming via policies
BRAVE_POLICY_DIR=/etc/brave/policies/managed
BRAVE_POLICY_FILE="$BRAVE_POLICY_DIR/noctalia-theme.json"
# Dir stays root-owned 755; only this one file is writable by your user.
sudo install -d -m 755 -o root -g root "$BRAVE_POLICY_DIR"
[ -f "$BRAVE_POLICY_FILE" ] || echo '{}' | sudo tee "$BRAVE_POLICY_FILE" >/dev/null
sudo chown "$USER:root" "$BRAVE_POLICY_FILE"
sudo chmod 644 "$BRAVE_POLICY_FILE"

if ! mega-whoami &>/dev/null; then
    mega-login --auth-code="$(bw_get totp mega.nz)" "$(bw_get username mega.nz)" "$(bw_get password mega.nz)"
fi
msg "mega: $(mega-whoami | head -n1)"

ensure_mega_sync "$HOME/Music" "Music"
ensure_mega_sync "$HOME/Pictures" "Pictures"
ensure_mega_sync "$HOME/Videos" "Videos"
ensure_mega_sync "$HOME/Documents" "Documents"
mega-sync-ignore --add-exclusion dN:vimwiki "$HOME/Documents"

# "install" my notes in documents
if [[ ! -d ~/Documents/vimwiki ]]; then
    GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new' git clone git@gitlab.com:gayboys/notes.git "$HOME/Documents/vimwiki"
fi
msg "notes: cloned"

sudo systemctl enable docker.socket
sudo systemctl start docker.socket
sudo docker run --rm hello-world > /dev/null
msg "docker: enabled & operational"

# reload copyq to apply config and ensure it's server is running
copyq exit 2>/dev/null || true; uwsm app -- copyq --start-server &

###############################################################################
# cleanup
###############################################################################
rm -r "$email_cache"
}
)
