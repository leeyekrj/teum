#!/bin/bash
# Teum GitHub installer. Does not change AI host settings or disable Gatekeeper.
set -euo pipefail
version=v1.0.5
app_dir=/Applications
bin_dir="$HOME/.local/bin"
launch=1
cli=1
die() { printf 'Teum: %s\n' "$*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version|--app-dir|--bin-dir)
      [ "$#" -ge 2 ] || die "$1 값이 필요합니다."
      case "$1" in --version) version="$2";; --app-dir) app_dir="$2";; --bin-dir) bin_dir="$2";; esac
      shift 2;;
    --no-open) launch=0; shift;;
    --skip-cli) cli=0; shift;;
    --help) printf '%s\n' '사용: bash install.sh [--version v1.0.5] [--app-dir 경로] [--bin-dir 경로] [--no-open] [--skip-cli]'; exit 0;;
    *) die "알 수 없는 옵션: $1";;
  esac
done
[ "$(uname -s)" = Darwin ] || die 'macOS 14 이상에서 설치할 수 있습니다.'
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || die 'macOS 14 이상이 필요합니다.'
case "$(uname -m)" in arm64|x86_64) ;; *) die 'Apple Silicon 또는 Intel Mac이 필요합니다.';; esac
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die '버전 형식은 v1.0.5입니다.'
case "$app_dir:$bin_dir" in *$'\n'*|*$'\r'*) die '경로에 줄바꿈을 쓸 수 없습니다.';; esac
case "$app_dir" in /*) ;; *) die '--app-dir에는 절대 경로를 사용하세요.';; esac
case "$bin_dir" in /*) ;; *) die '--bin-dir에는 절대 경로를 사용하세요.';; esac
if [ "$app_dir" = /Applications ] && [ ! -w /Applications ]; then app_dir="$HOME/Applications"; fi
app="$app_dir/Teum.app"
if /bin/ps -axo comm= | /usr/bin/grep -Fxq "$app/Contents/MacOS/Teum"; then
  die 'Teum을 메뉴에서 종료한 뒤 다시 설치하세요. 설정과 기록은 유지됩니다.'
fi
if [ "$cli" = 1 ] && { [ -e "$bin_dir/teum-cli" ] || [ -L "$bin_dir/teum-cli" ]; }; then
  /usr/bin/grep -q '^# Teum GitHub installer' "$bin_dir/teum-cli" || die '기존 teum-cli가 있습니다. --skip-cli를 사용하거나 기존 설치를 먼저 확인하세요.'
fi
tmp=$(mktemp -d "${TMPDIR:-/tmp}/teum-install.XXXXXX")
stage=''; backup=''
cleanup() {
  [ -z "$stage" ] || rm -rf "$stage"
  if [ -n "$backup" ] && [ -d "$backup" ] && [ ! -e "$app" ]; then mv "$backup" "$app"; fi
  rm -rf "$tmp"
}
trap cleanup EXIT
asset="Teum-${version#v}-macOS-universal.zip"
base="https://github.com/leeyekrj/teum/releases/download/$version"
printf 'Teum %s 다운로드 중…\n' "$version"
curl --fail --location --retry 3 --proto '=https' --tlsv1.2 "$base/$asset" -o "$tmp/$asset"
curl --fail --location --retry 3 --proto '=https' --tlsv1.2 "$base/SHA256SUMS.txt" -o "$tmp/SHA256SUMS.txt"
expected=$(awk -v file="$asset" '$2 == file {print $1}' "$tmp/SHA256SUMS.txt")
[[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die '릴리스의 SHA256을 확인할 수 없습니다.'
actual=$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')
[ "$actual" = "$expected" ] || die '다운로드 검증 실패. 설치하지 않았습니다.'
ditto -x -k "$tmp/$asset" "$tmp/unpacked"
source_app="$tmp/unpacked/Teum.app"
codesign --verify --strict "$source_app"
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$source_app/Contents/Info.plist")" = io.paul.teum ] || die '앱 식별자가 다릅니다.'
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$source_app/Contents/Info.plist")" = "${version#v}" ] || die '앱 버전이 다릅니다.'
mkdir -p "$app_dir"
stage=$(mktemp -d "$app_dir/.teum-install.XXXXXX")
ditto "$source_app" "$stage/Teum.app"
if [ -e "$app" ]; then
  backup="$app_dir/Teum.app.backup-$(date +%Y%m%d-%H%M%S)-$$"
  mv "$app" "$backup"
fi
mv "$stage/Teum.app" "$app"
if [ "$cli" = 1 ]; then
  mkdir -p "$bin_dir"
  # Quote an arbitrary application path as a bash literal.
  printf -v quoted '%q' "$app/Contents/Resources/cli/teum_cli.py"
  printf '#!/bin/bash\n# Teum GitHub installer\nexec python3 %s "$@"\n' "$quoted" > "$tmp/teum-cli"
  chmod 755 "$tmp/teum-cli"
  mv "$tmp/teum-cli" "$bin_dir/teum-cli"
  printf 'CLI: %s/teum-cli (Python 3.9 이상 필요)\n' "$bin_dir"
  case ":$PATH:" in *":$bin_dir:"*) ;; *) printf 'PATH에 %s를 추가하면 teum-cli를 바로 쓸 수 있습니다.\n' "$bin_dir";; esac
fi
printf '설치 완료: %s\n' "$app"
[ -z "$backup" ] || printf '이전 앱 백업: %s\n' "$backup"
printf '%s\n' '현재 릴리스는 Apple 미공증 앱입니다. 실행이 차단되면 시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기를 확인하세요.'
if [ "$launch" = 1 ]; then open "$app" || printf '앱을 직접 열어 주세요.\n'; fi
