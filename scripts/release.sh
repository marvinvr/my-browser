#!/bin/bash
# myBrowser release: Developer ID app + DMG, notarized and stapled, Sparkle EdDSA signature, appcast.
#
#   scripts/release.sh 0.1.0
#   scripts/release.sh --dry-run 0.1.0
#
# Signing uses the Developer ID Application certificate Strudel uses
# (Developer ID Application: Marvin von Rappard (WZ6VURTF6A), team WZ6VURTF6A).
# Notarization uses the same App Store Connect API key as Strudel (notarytool --key).
# Strudel has no notarytool keychain profile; set NOTARY_KEYCHAIN_PROFILE to use one instead.
# Credentials default to ~/.config/testflight/env (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH,
# SIGNING_KEYCHAIN, SIGNING_KEYCHAIN_PASSWORD_FILE).
#
# Sparkle signs with sign_update --ed-key-file ~/.config/my-browser/sparkle/ed25519.key (mode 0600).
# --dry-run builds, signs, notarizes and writes the appcast under build/dry-run. It does not run
# `gh release create`, commit, or push.
#
# Safe to re-run for the same version: the build number and a stapled DMG are reused.
set -euo pipefail
cd "$(dirname "$0")/.."

repo=marvinvr/my-browser
feed_url="https://raw.githubusercontent.com/$repo/main/appcast.xml"
identity=${CODESIGN_IDENTITY:-"Developer ID Application: Marvin von Rappard (WZ6VURTF6A)"}
team=WZ6VURTF6A
profile_name=${PROVISIONING_PROFILE_SPECIFIER:-"myBrowser Developer ID (Molty)"}
profile_uuid=${PROVISIONING_PROFILE_UUID:-9d84df52-1fe2-4b88-87b1-7c733aa485a5}
entitlements_file=myBrowser/myBrowser-iCloud.entitlements
key_file=${SPARKLE_ED_KEY_FILE:-$HOME/.config/my-browser/sparkle/ed25519.key}
version=""
dry_run=0

usage() { sed -n '2,16p' "$0"; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage ;;
    --) shift; break ;;
    -*) echo "unknown option: $1" >&2; exit 64 ;;
    *)
      [[ -z "$version" ]] || { echo "unexpected argument: $1" >&2; exit 64; }
      version=$1
      shift
      ;;
  esac
done
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: scripts/release.sh [--dry-run] <version>  (for example 0.1.0)" >&2; exit 64; }

# Strudel's notarization credentials. Values are not printed.
env_file=${ASC_ENV_FILE:-$HOME/.config/testflight/env}
if [[ -z "${ASC_KEY_PATH:-}" && -f "$env_file" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
fi

unlock_signing_keychain() {
  local kc=${SIGNING_KEYCHAIN:-$HOME/Library/Keychains/strudel-signing.keychain-db}
  local passfile=${SIGNING_KEYCHAIN_PASSWORD_FILE:-$HOME/.config/strudel/asc/dist/kc.pass}
  [[ -f "$kc" && -f "$passfile" ]] || { echo "Signing keychain or its password file is missing." >&2; exit 1; }
  local pass
  pass=$(<"$passfile")
  security unlock-keychain -p "$pass" "$kc"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pass" "$kc" >/dev/null
  unset pass
}

notarize() {
  local file=$1
  local result status id
  echo "Notarizing $(basename "$file")…"
  if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    result=$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait --output-format json) || true
  else
    : "${ASC_KEY_PATH:?set ASC_KEY_PATH (App Store Connect API key, the one Strudel uses)}"
    : "${ASC_KEY_ID:?set ASC_KEY_ID}"
    : "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
    [[ -f "$ASC_KEY_PATH" ]] || { echo "ASC_KEY_PATH does not exist: $ASC_KEY_PATH" >&2; exit 1; }
    result=$(xcrun notarytool submit "$file" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait --output-format json) || true
  fi
  echo "$result"
  status=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' <<<"$result" 2>/dev/null || true)
  if [[ "$status" != "Accepted" ]]; then
    id=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' <<<"$result" 2>/dev/null || true)
    if [[ -n "$id" ]]; then
      if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
        xcrun notarytool log "$id" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" || true
      else
        xcrun notarytool log "$id" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" || true
      fi
    fi
    echo "Notarization failed (${status:-no status})." >&2
    exit 1
  fi
}

sign_item() {
  local item=$1
  local ent id
  ent=$(mktemp)
  codesign -d --entitlements "$ent" "$item" >/dev/null 2>&1 || true
  # awk exits after the first match; without `|| true`, pipefail turns that SIGPIPE into a failure.
  id=$(codesign -d -v "$item" 2>&1 | awk -F= '/^Identifier=/{print $2; exit}') || true
  local args=(--force --options runtime --timestamp --sign "$identity")
  [[ -n "$id" ]] && args+=(--identifier "$id")
  if [[ -s "$ent" ]] && grep -q '<key>' "$ent"; then
    args+=(--entitlements "$ent")
  fi
  codesign "${args[@]}" "$item"
  rm -f "$ent"
}

# Inside-out. --deep is wrong: it resigns nested Sparkle code with the wrong signature.
sign_sparkle() {
  local app=$1
  local fw="$app/Contents/Frameworks/Sparkle.framework"
  local base="$fw/Versions/B"
  [[ -d "$base" ]] || { echo "Sparkle.framework is missing from $app" >&2; exit 1; }
  local item
  for item in \
    "$base/XPCServices/Downloader.xpc" \
    "$base/XPCServices/Installer.xpc" \
    "$base/Updater.app" \
    "$base/Autoupdate"
  do
    [[ -e "$item" ]] || { echo "Missing Sparkle component: $item" >&2; exit 1; }
    sign_item "$item"
  done
  sign_item "$fw"
  codesign --force --options runtime --timestamp --sign "$identity" \
    --entitlements "$entitlements_file" "$app"
}

# The Developer ID profile must be inside the bundle or macOS kills the app at launch.
embed_profile() {
  local app=$1
  local dest="$app/Contents/embedded.provisionprofile"
  if [[ -f "$dest" ]]; then
    return 0
  fi
  local src="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/${profile_uuid}.provisionprofile"
  [[ -f "$src" ]] || { echo "Provisioning profile is not installed: $src" >&2; exit 1; }
  cp "$src" "$dest"
}

verify_signed() {
  local item=$1
  local out
  out=$(codesign -dvvv "$item" 2>&1)
  grep -q "Authority=Developer ID Application: Marvin von Rappard (WZ6VURTF6A)" <<<"$out" || {
    echo "Not signed with the Developer ID certificate: $item" >&2
    echo "$out" >&2
    exit 1
  }
  grep -q "flags=0x10000(runtime)" <<<"$out" || { echo "Hardened runtime is off: $item" >&2; echo "$out" >&2; exit 1; }
  codesign --verify --strict "$item"
}

find_sparkle_bin() {
  local dir
  for dir in \
    "$work/SourcePackages/artifacts/sparkle/Sparkle/bin" \
    "$work/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin" \
    build/sparkle-tools/bin \
    "$HOME"/Library/Developer/Xcode/DerivedData/myBrowser-*/SourcePackages/artifacts/sparkle/Sparkle/bin
  do
    [[ -x "$dir/sign_update" ]] && { echo "$dir"; return 0; }
  done
  return 1
}

ensure_sparkle_bin() {
  sparkle_bin=$(find_sparkle_bin || true)
  if [[ -n "$sparkle_bin" ]]; then return 0; fi
  echo "Downloading Sparkle 2.10.0 tools…"
  mkdir -p build/sparkle-tools
  curl -fsSL -o build/sparkle-tools/Sparkle-2.10.0.tar.xz \
    https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz
  tar -xJf build/sparkle-tools/Sparkle-2.10.0.tar.xz -C build/sparkle-tools
  sparkle_bin=$(find_sparkle_bin || true)
  [[ -n "$sparkle_bin" && -x "$sparkle_bin/sign_update" ]] || { echo "Sparkle sign_update not found." >&2; exit 1; }
}

if [[ $dry_run == 1 ]]; then
  work=build/dry-run/$version
else
  work=build/release/$version
fi
mkdir -p "$work"
work=$(cd "$work" && pwd)

echo "Unlocking the Developer ID keychain…"
unlock_signing_keychain
idents=$(security find-identity -v -p codesigning || true)
grep -F "$identity" <<<"$idents" >/dev/null || {
  echo "No signing identity: $identity" >&2
  exit 1
}

[[ -f "$key_file" ]] || { echo "No Sparkle key file at $key_file" >&2; exit 1; }
mode=$(stat -f %Lp "$key_file")
[[ $mode == 600 || $mode == 400 ]] || { echo "$key_file must be mode 0600 (is $mode)" >&2; exit 1; }

state=$work/state.json
if [[ -f "$state" ]]; then
  build=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["build"])' "$state")
  echo "Resuming $version ($build)."
else
  build=$(python3 -c 'import re,sys; text=open(sys.argv[1]).read(); m=re.search(r"CURRENT_PROJECT_VERSION:\s*\"(\d+)\"", text); print(m.group(1) if m else "")' project.yml)
  [[ $build =~ ^[0-9]+$ ]] || { echo "Could not read CURRENT_PROJECT_VERSION from project.yml" >&2; exit 1; }
  build=$((build + 1))
  printf '{"version":"%s","build":"%s"}\n' "$version" "$build" > "$state"
  echo "Version $version, build $build."
fi

python3 - "$version" "$build" <<'PY'
import re, sys
version, build = sys.argv[1], sys.argv[2]
path = "project.yml"
text = open(path).read()
text, n1 = re.subn(r'^(\s*MARKETING_VERSION:\s*")[^"]+(")', rf'\g<1>{version}\2', text, count=1, flags=re.M)
text, n2 = re.subn(r'^(\s*CURRENT_PROJECT_VERSION:\s*")[^"]+(")', rf'\g<1>{build}\2', text, count=1, flags=re.M)
if n1 != 1 or n2 != 1:
    sys.exit(f"version bump failed (marketing={n1}, build={n2})")
open(path, "w").write(text)
PY

command -v xcodegen >/dev/null || { echo "xcodegen is required." >&2; exit 1; }
xcodegen generate --quiet

min_system=$(sed -n 's/^ *macOS: *"\{0,1\}\([0-9.]*\)"\{0,1\}$/\1/p' project.yml)
min_system=${min_system%%$'\n'*}
[[ -n "$min_system" ]] || min_system=26.0

dmg_name="myBrowser-$version-$build.dmg"
dmg="$work/$dmg_name"
app="$work/export/myBrowser.app"

if [[ -f "$dmg" ]] && xcrun stapler validate -q "$dmg" 2>/dev/null; then
  echo "Reusing stapled $dmg"
else
  echo "Archiving myBrowser $version ($build)…"
  if ! xcodebuild -project myBrowser.xcodeproj -scheme myBrowser -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$work/myBrowser.xcarchive" \
    -derivedDataPath "$work/DerivedData" \
    -clonedSourcePackagesDirPath "$work/SourcePackages" \
    CODE_SIGN_STYLE=Manual \
    "CODE_SIGN_IDENTITY=$identity" \
    "DEVELOPMENT_TEAM=$team" \
    "PROVISIONING_PROFILE_SPECIFIER=$profile_name" \
    CODE_SIGN_ENTITLEMENTS="$entitlements_file" \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    "MARKETING_VERSION=$version" \
    "CURRENT_PROJECT_VERSION=$build" \
    archive > "$work/archive.log" 2>&1
  then
    echo "Archive failed. Last lines of $work/archive.log:" >&2
    tail -80 "$work/archive.log" >&2
    exit 1
  fi
  [[ -d "$work/myBrowser.xcarchive" ]] || { echo "Archive produced no .xcarchive." >&2; exit 1; }

  cat > "$work/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>ch.marvinvr.mybrowser</key>
    <string>$profile_name</string>
  </dict>
  <key>destination</key><string>export</string>
</dict>
</plist>
PLIST

  echo "Exporting (Developer ID)…"
  rm -rf "$work/export"
  if ! xcodebuild -exportArchive \
    -archivePath "$work/myBrowser.xcarchive" \
    -exportPath "$work/export" \
    -exportOptionsPlist "$work/ExportOptions.plist" > "$work/export.log" 2>&1
  then
    # Export can fail to copy a manually specified Developer ID profile. The archived
    # app is already signed; embed that profile before sign_sparkle seals it.
    if grep -q "No profiles for" "$work/export.log"; then
      echo "Export did not embed a profile; copying the archive and embedding ${profile_name}."
      mkdir -p "$work/export"
      ditto "$work/myBrowser.xcarchive/Products/Applications/myBrowser.app" "$app"
    else
      echo "Export failed. Last lines of $work/export.log:" >&2
      tail -80 "$work/export.log" >&2
      exit 1
    fi
  fi
  [[ -d "$app" ]] || { echo "Export did not produce $app" >&2; exit 1; }
  embed_profile "$app"
  [[ -f "$app/Contents/embedded.provisionprofile" ]] || { echo "Release app is missing Contents/embedded.provisionprofile." >&2; exit 1; }

  echo "Signing Sparkle components…"
  sign_sparkle "$app"
  verify_signed "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
  verify_signed "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
  verify_signed "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
  verify_signed "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
  verify_signed "$app/Contents/Frameworks/Sparkle.framework"
  verify_signed "$app"
  codesign --verify --deep --strict --verbose=2 "$app"

  [[ -f "$app/Contents/embedded.provisionprofile" ]] || { echo "Release app is missing Contents/embedded.provisionprofile." >&2; exit 1; }
  entitlements=$(codesign -d --entitlements :- "$app" 2>/dev/null || true)
  grep -q "get-task-allow" <<<"$entitlements" && { echo "Release app is signed with get-task-allow." >&2; exit 1; }
  grep -q "com.apple.security.cs.allow-jit" <<<"$entitlements" || { echo "Release app is missing the JIT entitlement." >&2; exit 1; }
  grep -q "iCloud.ch.marvinvr.mybrowser" <<<"$entitlements" || { echo "Release app is missing the iCloud container entitlement." >&2; exit 1; }
  grep -q "com.apple.developer.icloud-services" <<<"$entitlements" || { echo "Release app is missing the CloudKit entitlement." >&2; exit 1; }
  grep -q "com.apple.developer.icloud-container-environment" <<<"$entitlements" || { echo "Release app is missing the iCloud environment entitlement." >&2; exit 1; }
  grep -q "com.apple.developer.aps-environment" <<<"$entitlements" || { echo "Release app is missing the push entitlement." >&2; exit 1; }
  if grep -a -R -F -q "ch.marvinvr.mybrowser.debug.snapshot" "$app/Contents/MacOS"; then
    echo "DEBUG snapshot hook is present in the Release binary." >&2
    exit 1
  fi

  plist_key=$(/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" "$app/Contents/Info.plist")
  file_key=$(swift scripts/sparkle-key.swift public "$key_file")
  [[ "$plist_key" == "$file_key" ]] || {
    echo "SUPublicEDKey ($plist_key) does not match $key_file ($file_key)." >&2
    exit 1
  }

  echo "Notarizing the app…"
  ditto -c -k --keepParent "$app" "$work/myBrowser.zip"
  notarize "$work/myBrowser.zip"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  [[ -f "$app/Contents/embedded.provisionprofile" ]] || { echo "Stapled app lost Contents/embedded.provisionprofile." >&2; exit 1; }

  stage=$work/stage
  rm -rf "$stage"
  mkdir -p "$stage"
  ditto "$app" "$stage/myBrowser.app"
  ln -s /Applications "$stage/Applications"
  rm -f "$dmg"
  hdiutil create -volname "myBrowser" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
  codesign --sign "$identity" --timestamp "$dmg"
  echo "Notarizing the DMG…"
  notarize "$dmg"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
fi

ensure_sparkle_bin
signed=$("$sparkle_bin/sign_update" --ed-key-file "$key_file" "$dmg")
signature=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$signed")
length=$(sed -n 's/.*length="\([0-9]*\)".*/\1/p' <<<"$signed")
[[ -n "$signature" && -n "$length" ]] || { echo "sign_update failed: $signed" >&2; exit 1; }
echo "Sparkle signature length=$length"

head=$(git rev-parse HEAD)
git log --no-merges --format=%s -15 > "$work/subjects.txt"
python3 scripts/appcast.py notes "$work/subjects.txt" "$work/notes.md"
url="https://github.com/$repo/releases/download/v$version/$dmg_name"
page="https://github.com/$repo/releases/tag/v$version"

if [[ $dry_run == 1 ]]; then
  python3 scripts/appcast.py upsert "$work/releases.json" --version "$version" --build "$build" --commit "$head" \
    --url "$url" --length "$length" --signature "$signature" --min-system "$min_system" \
    --notes-file "$work/notes.md" --page "$page"
  python3 scripts/appcast.py render "$work/releases.json" "$work/appcast.xml" --feed-url "$feed_url"
  echo "Dry run finished: $dmg"
  echo "Appcast (not published): $work/appcast.xml"
  echo "Skipped gh release create, commit, and push."
  exit 0
fi

db=releases.json
python3 scripts/appcast.py upsert "$db" --version "$version" --build "$build" --commit "$head" \
  --url "$url" --length "$length" --signature "$signature" --min-system "$min_system" \
  --notes-file "$work/notes.md" --page "$page"
python3 scripts/appcast.py render "$db" appcast.xml --feed-url "$feed_url"

{
  cat "$work/notes.md"
  printf '\nmacOS %s or later. Open the DMG and drag myBrowser to Applications. Installed copies update themselves (Sparkle).\n' "$min_system"
} > "$work/release-notes.md"

command -v gh >/dev/null || { echo "gh is required to publish." >&2; exit 1; }
if gh release view "v$version" -R "$repo" >/dev/null 2>&1; then
  echo "Release v$version exists; uploading the DMG…"
  gh release upload "v$version" "$dmg" -R "$repo" --clobber
else
  gh release create "v$version" "$dmg" -R "$repo" \
    --title "myBrowser $version" --notes-file "$work/release-notes.md"
fi

branch=$(git branch --show-current)
[[ "$branch" == "main" ]] || { echo "Publish commits to main (current branch is $branch)." >&2; exit 1; }
[[ -z "$(git diff --cached --name-only)" ]] || { echo "The index is not clean; refusing to commit the release." >&2; exit 1; }
git add project.yml appcast.xml releases.json
if git diff --cached --quiet; then
  echo "Nothing to commit."
else
  git commit -m "Release v$version"
fi
git push origin main
echo "Released myBrowser $version ($build): $page"
echo "Feed: $feed_url"
