#!/bin/sh
# Fork-only: build Spaceman.app for this Intel Mac and sign it with a stable,
# self-signed identity, so macOS keeps the Accessibility grant across rebuilds
# (an ad-hoc signature changes with every build).
#
#   scripts/build-intel-app.sh            build target/Spaceman.app
#   scripts/build-intel-app.sh --install  also install it with scripts/install-app.sh
#                                         (restores windows, replaces /Applications/Spaceman.app,
#                                         links ~/.local/bin/spaceman, reopens it)
#
# The build is a source build: the in-app updater stays off, because it only
# knows the macos-arm64 release and would replace this build with it.
#
# The first run creates the "Spaceman Local Signing" certificate in the login
# keychain and asks once for your password to trust it for code signing.
# Override the name with SPACEMAN_LOCAL_SIGN_IDENTITY.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
identity=${SPACEMAN_LOCAL_SIGN_IDENTITY:-Spaceman Local Signing}
keychain="$HOME/Library/Keychains/login.keychain-db"

case "${1:-}" in
  ''|--install) ;;
  *) echo "usage: $0 [--install]" >&2; exit 2 ;;
esac

ensure_identity() {
  if security find-identity -v -p codesigning "$keychain" | grep -qF "\"$identity\""; then
    return
  fi
  echo "Creating the self-signed code-signing identity \"$identity\"." >&2
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=$identity" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
  # macOS's importer reads only the older PKCS#12 algorithms.
  openssl pkcs12 -export -legacy -passout pass:spaceman \
    -inkey "$work/key.pem" -in "$work/cert.pem" -out "$work/identity.p12"
  security import "$work/identity.p12" -k "$keychain" -P spaceman -T /usr/bin/codesign >&2
  echo "macOS asks for your password to trust the certificate for code signing." >&2
  security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$work/cert.pem"
  rm -rf "$work"
  trap - EXIT
  security find-identity -v -p codesigning "$keychain" | grep -qF "\"$identity\"" || {
    echo "The identity \"$identity\" is not valid for code signing." >&2
    exit 1
  }
}

ensure_identity

# build-app.sh's unsigned mode exports SPACEMAN_RELEASE_BUILD=1, which turns the
# updater on (src/updater.rs reads it at compile time). Give it a cargo that
# drops the release stamps, so this stays a source build. The wrapper runs
# Cargo through mbx (`mbx <cargo args>`), and unsets CARGO, because mbx reads
# it to find the real Cargo.
command -v mbx >/dev/null 2>&1 || { echo "mbx was not found; install it with: cargo install mbx --locked" >&2; exit 1; }
mbx_bin=$(command -v mbx)
wrapper_dir=$(mktemp -d)
trap 'rm -rf "$wrapper_dir"' EXIT
cat >"$wrapper_dir/cargo" <<EOF
#!/bin/sh
exec env -u CARGO -u SPACEMAN_RELEASE_BUILD -u SPACEMAN_RELEASE_CHANNEL -u SPACEMAN_RELEASE_VERSION "$mbx_bin" "\$@"
EOF
chmod 755 "$wrapper_dir/cargo"

bundle=$(CARGO="$wrapper_dir/cargo" SPACEMAN_RELEASE_UNSIGNED=1 "$root/scripts/build-app.sh" | tail -n 1)
for executable in spaceman-agent spaceman; do
  case "$(lipo -archs "$bundle/Contents/MacOS/$executable")" in
    x86_64) ;;
    *) echo "Expected an x86_64 $executable in $bundle." >&2; exit 1 ;;
  esac
done

# Sign inside out, with the same options and identifiers as scripts/build-app.sh.
# spaceman-agent is the bundle's main executable, so codesign checks the other
# executable first: sign spaceman before it.
sign() { codesign --force --options runtime --sign "$identity" "$@"; }
sign "$bundle/Contents/MacOS/spaceman"
sign "$bundle/Contents/MacOS/spaceman-agent"
sign --identifier anomaly.spaceman "$bundle"
codesign --verify --deep --strict "$bundle"

if [ "${1:-}" = --install ]; then
  "$root/scripts/install-app.sh" --bundle "$bundle"
else
  echo "$bundle"
fi
