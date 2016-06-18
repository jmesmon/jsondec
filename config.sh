## config.sh: d1f60e4+, see https://github.com/jmesmon/cninja.git
# ex: sts=8 sw=8 ts=8 noet
set -eu

D="$(dirname "$0")"
: ${SRC_DIR:="$D"}
: ${OBJ_DIR:="."}

: ${HOST_CC:=cc}
: ${HOST_LDFLAGS:=}

: ${CROSS_COMPILER:=}
: ${CC:=${CROSS_COMPILER}cc}
: ${OBJCOPY:=${CROSS_COMPILER}objcopy}

# FIXME: do we need a env wrapper here? (yes)
: ${HOST_PKGCONFIG:=pkg-config}
: ${PKGCONFIG:=pkg-config}

# XXX: convenience only
: ${GIT_VER:=$(${GIT:-git} describe --dirty=+ --always 2>/dev/null || echo "+")}

: ${WARN_FLAGS_C:="-Wstrict-prototypes -Wmissing-prototypes -Wold-style-definition -Wmissing-declarations -Wbad-function-cast"}
: ${WARN_FLAGS:="-Wall -Wundef -Wshadow -Wcast-align -Wwrite-strings -Wextra -Werror=attributes -Wno-missing-field-initializers ${WARN_FLAGS_C}"}

# XXX: handle for HOST too
# XXX: consider parallelizing invocation here?
if [ -n "${PKGCONFIG_LIBS:=}" ]; then
	PKGCONFIG_CFLAGS="$(${PKGCONFIG} --cflags ${PKGCONFIG_LIBS})"
	PKGCONFIG_LDFLAGS="$(${PKGCONFIG} --libs ${PKGCONFIG_LIBS})"
else
	PKGCONFIG_CFLAGS=""
	PKGCONFIG_LDFLAGS=""
fi

LIB_CFLAGS="${LIB_CFLAGS:-} ${PKGCONFIG_CFLAGS} "
LIB_LDFLAGS="${LIB_LDFLAGS:-} ${PKGCONFIG_LDFLAGS}"

ALL_CFLAGS="${WARN_FLAGS}"

if_runs () {
	local y="$1"
	local n="$2"
	shift 2
	"$@" >/dev/null 2>&1 && printf "%s" "$y" || printf "%s" "$n"
}

# Given a series of flags for CC, echo (space seperated) the ones that the
# compiler is happy with.
# XXX: Note that this does mean flags with spaces in them won't work.
cflag_x () {
	local cc=$(eval printf "%s" "\${$1CC}")
	local cflags=$(eval printf "%s" "\${$1CFLAGS:-}")
	shift
	for i in "$@"; do
		if_runs "$i " "" $cc $cflags -c -x c "$i" /dev/null -o /dev/null
	done
}

try_run() {
	"$@" >/dev/null 2>&1
}

cflag_first () {
	local cc=$(eval printf "%s" "\${$1CC}")
	local cflags=$(eval printf "%s" "\${$1CFLAGS:-}")
	shift
	for i in "$@"; do
		if try_run $cc $cflags -c -x c "$i" /dev/null -o /dev/null; then
			echo "$i"
			return
		fi
	done
}

die () {
	>&2 echo "Error: $*"
	exit 1
}

: ${EXTRA_FLAGS=}

: ${SANITIZE_FLAGS="$(cflag_x "" -fsanitize=address -fsanitize=undefined)"}
: ${DEBUG_FLAGS="$(cflag_x "" -ggdb3 -fvar-tracking-assignments)"}
: ${LTO_FLAGS="$(cflag_x "" -flto)"}
: ${OPT_FLAGS="$(cflag_first "" -Og -Os -O2)"}

COMMON_FLAGS="${SANITIZE_FLAGS} ${DEBUG_FLAGS} ${LTO_FLAGS}"

: ${CFLAGS="${ALL_CFLAGS} ${COMMON_FLAGS} ${OPT_FLAGS} ${EXTRA_FLAGS}"}

if [ -n "${LTO_FLAGS}" ]; then
	COMMON_FLAGS="${COMMON_FLAGS} ${OPT_FLAGS}"
fi

# Without LIB_CFLAGS
# FIXME: may not be entirely correct, sometimes we'll want libraries in host binaries
: ${HOST_CFLAGS:=${CFLAGS:-}}

CFLAGS="-DCFG_GIT_VERSION=${GIT_VER} -I. ${LIB_CFLAGS} ${CFLAGS:-}"

: ${LDFLAGS:="${COMMON_FLAGS}"}
LDFLAGS="${LIB_LDFLAGS} ${LDFLAGS} ${DEBUG_FLAGS}"

CONFIG_H_GEN=./config_h_gen

CONFIGS=""

: ${CPPFLAGS=}

# Check if compiler likes -MMD -MF
if $CC $CFLAGS -MMD -MF /dev/null -c -x c /dev/null -o /dev/null >/dev/null 2>&1; then
	DEP_LINE="  depfile = \$out.d"
	DEP_FLAGS="-MMD -MF \$out.d"
else
	DEP_LINE=""
	DEP_FLAGS=""
fi

exec 5>build.ninja
>&5 echo "# generated by config.sh"

>&5 cat <<EOF
host_cc = $HOST_CC
host_cflags = $HOST_CFLAGS
host_ldflags = $HOST_LDFLAGS
cc = $CC
objcopy = $OBJCOPY
cflags = $CFLAGS
ldflags = $LDFLAGS
cppflags = $CPPFLAGS

rule cc
  command = \$cc \$cflags $DEP_FLAGS  -c \$in -o \$out
$DEP_LINE

rule cc_fail
  command = ! \$cc \$cflags $DEP_FLAGS -c \$in -o \$out
$DEP_LINE

rule cc_host
  command = \$host_cc \$host_cflags $DEP_FLAGS -c \$in -o \$out
$DEP_LINE

rule ccld_host
  command = \$host_cc \$host_ldflags -o \$out \$in

rule ccld
  command = \$cc \$ldflags -o \$out \$in

rule config_h_frag
  command = ${CONFIG_H_GEN} \$in \$cc \$cflags \$ldflags > \$out

rule combine
  command = cat \$in > \$out

rule ninja_gen
  command = $0
  generator = yes
EOF

CONFIGURE_DEPS="$0"

# <target>
target_dir() {
	local target="$1"
	printf "%s" ".build-$target"
}

# <target>
target_ldflags() {
	local target="$1"
	local v="$(var_name "$target")"
	_ev "ldflags_$v:-"
}

var_name() {
	echo "$1" | sed -e 's/-/_/'	
}

# <target>
target_cflags() {
	local target="$1"
	local v="$(var_name "$target")"
	_ev "cflags_$v:-"
	_ev "cppflags_$v:-"
}

# <target> <src-file>...
to_obj () {
	local target="$1"
	shift
	for i in "$@"; do
		printf "%s " "$(target_dir "$target")/$i.o"
	done
}

_ev () {
	eval printf "%s " "\${$1}"
}

config () {
	local configs=""
	for i in "$D"/config_h/*.c; do
		local name=".config.h-$i-frag"
		>&5 echo "build $name : config_h_frag $i | "$D"/if_compiles ${CONFIG_H_GEN}"
		configs="$configs $name"
	done

	echo "build config.h : combine $D/config_h/prefix.h $configs $D/config_h/suffix.h"
}

if [ -e "config_h" ]; then
	CONFIG_H=true
else
	CONFIG_H=false
fi

# If any files in config_h change, we need to re-generate build.ninja
if $CONFIG_H; then
	CONFIGURE_DEPS="$CONFIGURE_DEPS config_h/ ${CONFIG_H_GEN}"
fi

e_if() {
	local v=$1
	shift
	if $v; then
		echo "$@"
	fi
}

# <target> <src> [<act>]
# uses: CONFIG_H
obj() {
	local target=$1
	local s=$2
	shift
	shift
	local act=cc
	if [ $# -ne 0 ]; then
		act=$1
		shift
	fi

	>&5 cat <<EOF
build $(to_obj "$target" "$s"): $act $s | $(e_if $CONFIG_H config.h)
  cflags = \$cflags -I$(target_dir "$target") $(target_cflags "$target")
EOF
}

# <target> <obj>...
bin_base () {
	local target="$1"
	shift

	>&5 cat <<EOF
build $target : ccld $@
  ldflags = -L$(target_dir "$target") \$ldflags $(target_ldflags "$target")
EOF
}

# <target> <src>...
bin() {
	if [ "$#" -lt 2 ]; then
		die "'bin $1' has to have some source"
	fi
	local target="$1"
	shift

	for s in "$@"; do
		obj "$target" "$s"
	done

	bin_base "$target" $(to_obj "$target" "$@")
	>&5 echo "default $target"
}

# <target> <src>
host_obj() {
	local target="$1"
	>&5 cat <<EOF
build $(to_obj "$target" "$s"): cc_host $s | $(e_if $CONFIG_H config.h)
EOF
}

# <target> <src>...
host_bin() {
	local target="$1"
	shift

	for s in "$@"; do
		host_obj "$target" "$s"
	done

	>&5 cat <<EOF
build $target : ccld_host $@
EOF
}

# <target>
host_run() {
	>&2 echo "warning: NOT running $1"
}

# <target> <file>
add_run_test() {
	local target=$1
	local f=$2
	local b=$(basename $f .c)

	host_bin "$target/$b" "$f"
	host_run "$target/$b" 
}

# Add a set of tests based on source files in a given directory
# 
# The type of test is determined by the first part of the file name.
# 
# Types:
# - compile tests: build the source file with the target compiler. Build
#   success is test success. Only the single file is compiled, nothing additional
#   is linked to it. (other than as specified by target link flags)
# - compile_fail tests: the same as compile tests, except build failure is test
#   success.
# - run tests: compile tests, but additionally run the test. (XXX: resolve
#   running target tests)
# - api tests: compile tests, but link the module we're a part of to the test object.
#
#
# 
#
# <target-name> <path-to-dir>
add_test_dir() {
	local target="$1/test"
	local f="$2"
	for f in "$f"/*; do
		b="$(basename "$f")"
		case "$b" in
		compile*.c)
			obj "$target" "$f"
			>&5 echo "default $(to_obj "$target" "$f")"
			;;
		compile_fail*.c)
			obj "$target" "$f" cc_fail
			>&5 echo "default $(to_obj "$target" "$f")"
			;;
		run*.c)
			obj "$target" "$f"
			>&5 echo "default $(to_obj "$target" "$f")"
			add_run_test "$target" "$f"
			;;
		api*.c)
			>&2 echo "api test not supported, skipped $f"
			;;
		esac
	done
}

# A module is a directory with a particular layout that gives us a library
# which can be linked against
#
# ./tests is a test dir as specified by `add_test_dir()`
# ./*.c are the source files compiled into objects and included in the library
# ./*.h are headers that are used as the library's public interface
#
# <directory>
add_module() {
	local m="$1"
	local f
	for f in "$D/$1"/*; do
		b="$(basename "$f")"
		if [ -d "$f" ]; then
			if [ "$b" = test ]; then
				add_test_dir "$m" "$f"
			else
				>&2 echo unknown dir $f
			fi
		else
			>&2 echo file $f
		fi
	done
}

end_of_ninja () {
	>&5 echo build build.ninja : ninja_gen $CONFIGURE_DEPS
}

trap end_of_ninja EXIT
