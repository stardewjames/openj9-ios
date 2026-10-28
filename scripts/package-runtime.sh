#!/usr/bin/env bash
#
# package-runtime.sh - turn the iOS jmods produced by `make jdk-image` into a
# jlink'ed Java runtime laid out as iOS frameworks (one framework per dylib).
#
# Layout produced (see the port contract):
#   <out>/<sdk>/Frameworks/<stem>.framework/<stem>        (from lib[/default]/lib<stem>.dylib)
#   <out>/<sdk>/Frameworks/<stem>.framework/Info.plist
#   <out>/<sdk>/Frameworks/jvm.framework/javahome/...     (all non-Mach-O content of the image)
#   <out>/<sdk>/Frameworks/jvm.framework/PrivacyInfo.xcprivacy
#   <out>/<sdk>/frameworks.txt                            (packaged framework stems, one per line)
#
# Requires macOS with Xcode (xcrun, otool, install_name_tool, lipo, plutil, file).
# Binaries are NOT signed here: Xcode signs frameworks when it embeds them.
#
# Compatible with the stock macOS bash 3.2 (no associative arrays, no mapfile).

set -euo pipefail

SCRIPT_NAME=$(basename "$0")

DEFAULT_MODULES="java.base,java.compiler,java.datatransfer,java.desktop,java.instrument,java.logging,\
java.management,java.management.rmi,java.naming,java.net.http,java.prefs,java.rmi,\
java.scripting,java.security.jgss,java.security.sasl,java.sql,java.sql.rowset,\
java.transaction.xa,java.xml,java.xml.crypto,jdk.charsets,jdk.crypto.cryptoki,\
jdk.crypto.ec,jdk.dynalink,jdk.httpserver,jdk.jfr,jdk.localedata,jdk.management,\
jdk.naming.dns,jdk.naming.rmi,jdk.net,jdk.nio.mapmode,jdk.security.auth,\
jdk.security.jgss,jdk.unsupported,jdk.xml.dom,jdk.zipfs,openj9.jvm,openj9.sharedclasses"

# Libraries that are never packaged (stems, i.e. lib<stem>.dylib).
DROPPED_LIBS="jsig j9shr29"
# Image subtrees that are dropped entirely (relative to the image root).
DROPPED_DIRS="bin lib/server lib/j9vm"

# The rpaths every packaged binary ends up with.
RPATH_FRAMEWORKS_DIR="@loader_path/.."
RPATH_APP_FRAMEWORKS="@executable_path/Frameworks"

usage() {
	cat <<EOF
Usage: $SCRIPT_NAME --sdk <iphoneos|iphonesimulator> --jmods <dir> --jlink <path/to/jlink> --out <dir>
                    [--modules m1,m2,...] [--min-ios 15.0] [--version x.y.z]

  --sdk       Target SDK of the jmods (iphoneos = device, iphonesimulator = simulator).
  --jmods     Directory with the iOS *.jmod files (build/ios-<sdk>/images/jmods).
  --jlink     jlink executable of the host (macOS) JDK of the same version.
  --out       Output root; <out>/<sdk>/ is (re)created.
  --modules   Comma separated module list (default: the standard iOS runtime set).
              Modules not present in --jmods are skipped with a warning.
  --min-ios   MinimumOSVersion written to the Info.plists (default 15.0).
  --version   CFBundleVersion / CFBundleShortVersionString (default 21.0.13).
EOF
}

die() {
	echo "$SCRIPT_NAME: error: $*" >&2
	exit 1
}

warn() {
	echo "$SCRIPT_NAME: warning: $*" >&2
}

log() {
	echo "==> $*"
}

usage_error() {
	echo "$SCRIPT_NAME: $*" >&2
	usage >&2
	exit 2
}

# list_contains <needle> <space separated list>
list_contains() {
	local needle=$1 item
	for item in $2; do
		if [[ "$item" == "$needle" ]]; then
			return 0
		fi
	done
	return 1
}

SDK=""
JMODS=""
JLINK=""
OUT=""
MODULES_CSV="$DEFAULT_MODULES"
MIN_IOS="15.0"
VERSION="21.0.13"

while [[ $# -gt 0 ]]; do
	opt=$1
	case "$opt" in
	-h | --help)
		usage
		exit 0
		;;
	--sdk | --jmods | --jlink | --out | --modules | --min-ios | --version)
		[[ $# -ge 2 && -n "$2" ]] || usage_error "option $opt requires a value"
		val=$2
		shift 2
		;;
	--*=*)
		val=${opt#*=}
		opt=${opt%%=*}
		shift
		;;
	*)
		usage_error "unknown argument: $opt"
		;;
	esac
	case "$opt" in
	--sdk) SDK=$val ;;
	--jmods) JMODS=$val ;;
	--jlink) JLINK=$val ;;
	--out) OUT=$val ;;
	--modules) MODULES_CSV=$val ;;
	--min-ios) MIN_IOS=$val ;;
	--version) VERSION=$val ;;
	*) usage_error "unknown option: $opt" ;;
	esac
done

[[ -n "$SDK" ]] || usage_error "--sdk is required"
[[ -n "$JMODS" ]] || usage_error "--jmods is required"
[[ -n "$JLINK" ]] || usage_error "--jlink is required"
[[ -n "$OUT" ]] || usage_error "--out is required"

case "$SDK" in
iphoneos)
	PLATFORM_NUM=2
	PLATFORM_NAME=IOS
	BUNDLE_PLATFORM=iPhoneOS
	;;
iphonesimulator)
	PLATFORM_NUM=7
	PLATFORM_NAME=IOSSIMULATOR
	BUNDLE_PLATFORM=iPhoneSimulator
	;;
*)
	usage_error "--sdk must be iphoneos or iphonesimulator (got '$SDK')"
	;;
esac

[[ "$MIN_IOS" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || usage_error "--min-ios must look like 15.0 (got '$MIN_IOS')"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || usage_error "--version must be up to three dot-separated integers (got '$VERSION')"
[[ -d "$JMODS" ]] || die "--jmods directory does not exist: $JMODS"
[[ -x "$JLINK" ]] || die "--jlink is not executable: $JLINK"

for tool in xcrun plutil file; do
	command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool (this script must run on macOS with Xcode)"
done
OTOOL=$(xcrun --find otool) || die "xcrun cannot find otool"
INSTALL_NAME_TOOL=$(xcrun --find install_name_tool) || die "xcrun cannot find install_name_tool"
LIPO=$(xcrun --find lipo) || die "xcrun cannot find lipo"
SDKROOT_PATH=$(xcrun --sdk "$SDK" --show-sdk-path) || die "xcrun cannot find the $SDK SDK"

JMODS=$(cd "$JMODS" && pwd)
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
STAGE="$OUT/$SDK"
FRAMEWORKS="$STAGE/Frameworks"
WORK="$OUT/.work-$SDK"
IMAGE="$WORK/image"

cleanup() {
	rm -rf "$WORK"
}
trap cleanup EXIT

rm -rf "$STAGE" "$WORK"
mkdir -p "$FRAMEWORKS" "$WORK"

# ---------------------------------------------------------------------------
# 1. jlink
# ---------------------------------------------------------------------------

AVAILABLE_MODULES=""
for jmod in "$JMODS"/*.jmod; do
	[[ -e "$jmod" ]] || die "no *.jmod files in $JMODS"
	AVAILABLE_MODULES="$AVAILABLE_MODULES $(basename "$jmod" .jmod)"
done

SELECTED_MODULES=""
for module in ${MODULES_CSV//,/ }; do
	if list_contains "$module" "$AVAILABLE_MODULES"; then
		if ! list_contains "$module" "$SELECTED_MODULES"; then
			SELECTED_MODULES="$SELECTED_MODULES $module"
		fi
	else
		warn "module $module is not present in $JMODS; skipping it"
	fi
done
list_contains java.base "$SELECTED_MODULES" || die "java.base.jmod is missing from $JMODS"
list_contains java.desktop "$SELECTED_MODULES" || die "headless java.desktop is required for this runtime"
ADD_MODULES=$(echo $SELECTED_MODULES | tr ' ' ',')

log "jlink ($SDK): $ADD_MODULES"
JLINK_ARGS=(
	--module-path "$JMODS"
	--add-modules "$ADD_MODULES"
	--strip-debug
	--no-header-files
	--no-man-pages
	--output "$IMAGE"
)
"$JLINK" "${JLINK_ARGS[@]}" --compress=2 || die "jlink failed"
[[ -f "$IMAGE/lib/modules" ]] || die "jlink image has no lib/modules"

# ---------------------------------------------------------------------------
# 2. classify the image content
# ---------------------------------------------------------------------------

is_dropped_path() {
	local rel=$1 dir
	for dir in $DROPPED_DIRS; do
		if [[ "$rel" == "$dir" || "$rel" == "$dir/"* ]]; then
			return 0
		fi
	done
	return 1
}

JAVAHOME="$FRAMEWORKS/jvm.framework/javahome"
mkdir -p "$JAVAHOME"

# Recreate the directory structure (minus dropped subtrees) so that empty
# directories such as lib/default survive.
while IFS= read -r -d '' dir; do
	rel=${dir#"$IMAGE"}
	rel=${rel#/}
	[[ -n "$rel" ]] || continue
	is_dropped_path "$rel" && continue
	mkdir -p "$JAVAHOME/$rel"
done < <(find "$IMAGE" -type d -print0)

PACKAGED_STEMS=""
# Parallel list of "stem<TAB>source path" lines.
PACKAGED_SOURCES=""

while IFS= read -r -d '' path; do
	rel=${path#"$IMAGE"/}
	if is_dropped_path "$rel"; then
		continue
	fi
	desc=$(file -bL "$path" 2>/dev/null || true)
	if [[ "$desc" == Mach-O* ]]; then
		name=$(basename "$rel")
		if [[ -L "$path" ]]; then
			log "dropping Mach-O symlink $rel"
			continue
		fi
		if [[ "$name" != lib*.dylib || "$desc" != *"dynamically linked shared library"* ]]; then
			log "dropping Mach-O non-library $rel ($desc)"
			continue
		fi
		stem=${name#lib}
		stem=${stem%.dylib}
		if list_contains "$stem" "$DROPPED_LIBS"; then
			log "dropping $rel"
			continue
		fi
		if list_contains "$stem" "$PACKAGED_STEMS"; then
			die "two libraries map to $stem.framework: $rel and $(printf '%s\n' "$PACKAGED_SOURCES" | awk -F'\t' -v s="$stem" '$1 == s { print $2 }')"
		fi
		[[ "$stem" =~ ^[A-Za-z0-9_][A-Za-z0-9_.+-]*$ ]] || die "unsupported library name: $rel"
		PACKAGED_STEMS="$PACKAGED_STEMS $stem"
		PACKAGED_SOURCES+="$stem"$'\t'"$path"$'\n'
	else
		mkdir -p "$(dirname "$JAVAHOME/$rel")"
		# -L: jlink writes duplicate legal notices as symlinks; bundles must not contain them.
		if [[ -d "$path" ]]; then
			cp -RL "$path" "$JAVAHOME/$rel"
			chmod -R u+w,a+rX "$JAVAHOME/$rel"
		else
			cp -L "$path" "$JAVAHOME/$rel"
			chmod u+w,a+r "$JAVAHOME/$rel"
		fi
	fi
done < <(find "$IMAGE" \( -type f -o -type l \) -print0)

list_contains jvm "$PACKAGED_STEMS" || die "the image has no libjvm.dylib outside lib/server and lib/j9vm (expected lib/default/libjvm.dylib)"
[[ -f "$JAVAHOME/lib/modules" ]] || die "javahome is missing lib/modules"

# Install licensed, file-backed TrueType fonts for the headless Java2D renderer.
"$(cd "$(dirname "$0")" && pwd)/install-fonts.sh" "$JAVAHOME"

# ---------------------------------------------------------------------------
# 3. frameworks
# ---------------------------------------------------------------------------

bundle_id_for() {
	# CFBundleIdentifier allows [A-Za-z0-9.-] only.
	echo "org.openj9.ios.$(echo "$1" | LC_ALL=C sed -e 's/[^A-Za-z0-9.-]/-/g')"
}

write_info_plist() {
	local stem=$1 plist=$2
	cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$stem</string>
	<key>CFBundleIdentifier</key>
	<string>$(bundle_id_for "$stem")</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$stem</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>$BUNDLE_PLATFORM</string>
	</array>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>MinimumOSVersion</key>
	<string>$MIN_IOS</string>
</dict>
</plist>
EOF
	plutil -lint "$plist" >/dev/null || die "invalid Info.plist generated: $plist"
}

write_privacy_manifest() {
	local manifest=$1
	cat >"$manifest" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSPrivacyTracking</key>
	<false/>
	<key>NSPrivacyTrackingDomains</key>
	<array/>
	<key>NSPrivacyCollectedDataTypes</key>
	<array/>
	<key>NSPrivacyAccessedAPITypes</key>
	<array>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array>
				<string>C617.1</string>
			</array>
		</dict>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategorySystemBootTime</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array>
				<string>35F9.1</string>
			</array>
		</dict>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategoryDiskSpace</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array>
				<string>E174.1</string>
			</array>
		</dict>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategoryUserDefaults</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array>
				<string>CA92.1</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
EOF
	plutil -lint "$manifest" >/dev/null || die "invalid privacy manifest generated: $manifest"
}

# macho_info <binary>: prints "<LC name or PLATFORM/MINOS>\t<value>" lines for
# the install id, dylib load commands, rpaths and LC_BUILD_VERSION.
macho_info() {
	"$OTOOL" -l "$1" | awk '
		$1 == "cmd" { cmd = $2; next }
		($1 == "name" || $1 == "path") && cmd ~ /^LC_(ID_DYLIB|LOAD_DYLIB|LOAD_WEAK_DYLIB|REEXPORT_DYLIB|LAZY_LOAD_DYLIB|LOAD_UPWARD_DYLIB|RPATH)$/ {
			line = $0
			sub(/^[ \t]*(name|path)[ \t]+/, "", line)
			sub(/[ \t]+\(offset [0-9]+\)[ \t]*$/, "", line)
			print cmd "\t" line
			next
		}
		cmd == "LC_BUILD_VERSION" && $1 == "platform" { print "PLATFORM\t" $2; next }
		cmd == "LC_BUILD_VERSION" && $1 == "minos" { print "MINOS\t" $2; next }
	'
}

is_dylib_load_cmd() {
	case "$1" in
	LC_LOAD_DYLIB | LC_LOAD_WEAK_DYLIB | LC_REEXPORT_DYLIB | LC_LAZY_LOAD_DYLIB | LC_LOAD_UPWARD_DYLIB) return 0 ;;
	*) return 1 ;;
	esac
}

is_system_path() {
	case "$1" in
	/usr/lib/* | /System/Library/*) return 0 ;;
	*) return 1 ;;
	esac
}

# version_le a b: true if dotted version a <= b
version_le() {
	awk -v a="$1" -v b="$2" 'BEGIN {
		na = split(a, x, "."); nb = split(b, y, ".")
		n = (na > nb) ? na : nb
		for (i = 1; i <= n; i++) {
			xi = (i <= na) ? x[i] + 0 : 0; yi = (i <= nb) ? y[i] + 0 : 0
			if (xi < yi) exit 0
			if (xi > yi) exit 1
		}
		exit 0
	}'
}

rewrite_binary() {
	local stem=$1 bin=$2 cmd value base dep
	local -a change_args=()
	local -a old_rpaths=()

	while IFS=$'\t' read -r cmd value; do
		if is_dylib_load_cmd "$cmd"; then
			is_system_path "$value" && continue
			base=${value##*/}
			[[ "$base" == lib*.dylib ]] || continue
			dep=${base#lib}
			dep=${dep%.dylib}
			if list_contains "$dep" "$PACKAGED_STEMS"; then
				change_args+=(-change "$value" "@rpath/$dep.framework/$dep")
			elif list_contains "$dep" "$DROPPED_LIBS"; then
				die "$stem links against $value, which is dropped from the runtime (DROPPED_LIBS)"
			fi
		elif [[ "$cmd" == LC_RPATH ]]; then
			old_rpaths+=("$value")
		fi
	done < <(macho_info "$bin")

	local rpath
	for rpath in ${old_rpaths[@]+"${old_rpaths[@]}"}; do
		# One -delete_rpath per occurrence: duplicated LC_RPATHs are removed one at a time.
		"$INSTALL_NAME_TOOL" -delete_rpath "$rpath" "$bin"
	done
	"$INSTALL_NAME_TOOL" \
		-id "@rpath/$stem.framework/$stem" \
		${change_args[@]+"${change_args[@]}"} \
		-add_rpath "$RPATH_FRAMEWORKS_DIR" \
		-add_rpath "$RPATH_APP_FRAMEWORKS" \
		"$bin"
}

sdk_has_system_lib() {
	local path=$1
	[[ -e "$SDKROOT_PATH$path" || -e "$SDKROOT_PATH${path%.dylib}.tbd" || -e "$SDKROOT_PATH$path.tbd" ]]
}

verify_binary() {
	local stem=$1 bin=$2 cmd value dep
	local errors="" id="" platform="" minos="" rpaths=""

	local archs
	archs=$("$LIPO" -archs "$bin")
	[[ "$archs" == "arm64" ]] || errors="$errors
  architectures are '$archs', expected exactly 'arm64'"

	while IFS=$'\t' read -r cmd value; do
		case "$cmd" in
		LC_ID_DYLIB) id=$value ;;
		LC_RPATH) rpaths="$rpaths$value
" ;;
		PLATFORM) platform=$value ;;
		MINOS) minos=$value ;;
		*)
			if is_dylib_load_cmd "$cmd"; then
				if [[ "$value" == @rpath/*.framework/* ]]; then
					dep=${value#@rpath/}
					dep=${dep%%.framework/*}
					if [[ "$value" != "@rpath/$dep.framework/$dep" ]] || ! list_contains "$dep" "$PACKAGED_STEMS"; then
						errors="$errors
  $cmd $value does not refer to a packaged framework"
					fi
				elif is_system_path "$value"; then
					sdk_has_system_lib "$value" || errors="$errors
  $cmd $value does not exist in the $SDK SDK ($SDKROOT_PATH)"
				else
					errors="$errors
  $cmd $value is not a packaged framework or SDK library"
				fi
			fi
			;;
		esac
	done < <(macho_info "$bin")

	[[ "$id" == "@rpath/$stem.framework/$stem" ]] || errors="$errors
  LC_ID_DYLIB is '$id', expected '@rpath/$stem.framework/$stem'"

	local expected_rpaths
	expected_rpaths=$(printf '%s\n%s\n' "$RPATH_FRAMEWORKS_DIR" "$RPATH_APP_FRAMEWORKS" | sort)
	[[ "$(printf '%s' "$rpaths" | sort)" == "$expected_rpaths" ]] || errors="$errors
  LC_RPATHs are [$(printf '%s' "$rpaths" | tr '\n' ' ')], expected [$RPATH_FRAMEWORKS_DIR $RPATH_APP_FRAMEWORKS]"

	if [[ -z "$platform" ]]; then
		errors="$errors
  no LC_BUILD_VERSION load command"
	elif [[ "$platform" != "$PLATFORM_NUM" && "$platform" != "$PLATFORM_NAME" ]]; then
		errors="$errors
  LC_BUILD_VERSION platform is $platform, expected $PLATFORM_NAME ($PLATFORM_NUM) for $SDK"
	fi
	if [[ -n "$minos" ]] && ! version_le "$minos" "$MIN_IOS"; then
		errors="$errors
  LC_BUILD_VERSION minos $minos is newer than MinimumOSVersion $MIN_IOS"
	fi

	if [[ -n "$errors" ]]; then
		echo "$SCRIPT_NAME: error: $stem.framework/$stem failed verification:$errors" >&2
		"$OTOOL" -L "$bin" >&2 || true
		return 1
	fi
	return 0
}

for stem in $PACKAGED_STEMS; do
	src=$(printf '%s' "$PACKAGED_SOURCES" | awk -F'\t' -v s="$stem" '$1 == s { print $2; exit }')
	fw="$FRAMEWORKS/$stem.framework"
	log "$stem.framework <- ${src#"$IMAGE"/}"
	mkdir -p "$fw"
	cp "$src" "$fw/$stem"
	chmod 755 "$fw/$stem"
	write_info_plist "$stem" "$fw/Info.plist"
	rewrite_binary "$stem" "$fw/$stem"
done

write_privacy_manifest "$FRAMEWORKS/jvm.framework/PrivacyInfo.xcprivacy"

failed=0
for stem in $PACKAGED_STEMS; do
	verify_binary "$stem" "$FRAMEWORKS/$stem.framework/$stem" || failed=1
done
[[ $failed -eq 0 ]] || die "Mach-O verification failed (see above)"

# Nothing executable may remain inside javahome (it would need signing and is useless on iOS).
while IFS= read -r -d '' path; do
	desc=$(file -b "$path" 2>/dev/null || true)
	[[ "$desc" != Mach-O* ]] || die "Mach-O file left in javahome: ${path#"$JAVAHOME"/}"
done < <(find "$JAVAHOME" -type f -print0)
if [[ -n "$(find "$JAVAHOME" -type l -print -quit)" ]]; then
	die "symlink left in javahome: $(find "$JAVAHOME" -type l -print -quit)"
fi

printf '%s\n' $PACKAGED_STEMS | sort >"$STAGE/frameworks.txt"
log "packaged $(wc -l <"$STAGE/frameworks.txt" | tr -d ' ') frameworks into $FRAMEWORKS"
