#!/bin/sh
# Install the Coffee Shop guard into a project.
#
#   guard/install.sh <project-dir> [--enforce] [--uninstall]
#
# Installed files live under <project>/.pi/ and are added to the repository's
# local exclude file (.git/info/exclude), so they are never committed to the
# target project. --enforce switches the policy from annotate to block.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
target=""
mode="annotate"
uninstall=0

for arg in "$@"; do
	case "$arg" in
	--enforce) mode="block" ;;
	--annotate) mode="annotate" ;;
	--uninstall) uninstall=1 ;;
	-*)
		echo "unknown option: $arg" >&2
		exit 2
		;;
	*)
		if [ -n "$target" ]; then
			echo "usage: install.sh <project-dir> [--enforce] [--uninstall]" >&2
			exit 2
		fi
		target=$arg
		;;
	esac
done

if [ -z "$target" ] || [ ! -d "$target" ]; then
	echo "usage: install.sh <project-dir> [--enforce] [--uninstall]" >&2
	exit 2
fi
target=$(cd "$target" && pwd)

extension="$target/.pi/extensions/coffee-shop-guard.ts"
policy="$target/.pi/coffee-shop-guard.json"

# ensure_excluded appends a path to .git/info/exclude once. Local exclude keeps
# installed files out of the target repository without touching .gitignore.
ensure_excluded() {
	file=$1
	line=$2
	mkdir -p "$(dirname "$file")"
	touch "$file"
	if ! grep -Fqx "$line" "$file"; then
		printf '%s\n' "$line" >>"$file"
	fi
}

exclude_file=""
if git -C "$target" rev-parse --git-dir >/dev/null 2>&1; then
	exclude_file=$(cd "$target" && git rev-parse --git-path info/exclude)
	case "$exclude_file" in
	/*) ;;
	*) exclude_file="$target/$exclude_file" ;;
	esac
fi

if [ "$uninstall" -eq 1 ]; then
	rm -f "$extension" "$policy"
	echo "guard uninstalled from $target"
	echo "the exclude entries were left in place; remove them from ${exclude_file:-.git/info/exclude} if you want them gone"
	exit 0
fi

mkdir -p "$target/.pi/extensions"
cp "$here/coffee-shop-guard.ts" "$extension"

# The policy is data: start from the shipped default and set the mode.
sed "s/\"mode\": \"annotate\"/\"mode\": \"$mode\"/" "$here/policy.json" >"$policy"

if [ -n "$exclude_file" ]; then
	ensure_excluded "$exclude_file" "/.pi/extensions/coffee-shop-guard.ts"
	ensure_excluded "$exclude_file" "/.pi/coffee-shop-guard.json"
	ensure_excluded "$exclude_file" "/.rachel/"
fi

echo "coffee-shop guard installed in $target (mode: $mode)"
echo "  $extension"
echo "  $policy"
if [ -n "$exclude_file" ]; then
	echo "excluded locally in $exclude_file"
else
	echo "warning: $target is not a git repository; nothing was excluded"
fi
if [ "$mode" = "annotate" ]; then
	echo "raw build and test commands are allowed and annotated with the last verdict"
	echo "re-run with --enforce to block them"
else
	echo "raw build and test commands are blocked unless prefixed with CS_RAW=1"
fi
