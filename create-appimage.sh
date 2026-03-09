#!/bin/bash
#podman run -it --rm --privileged --volume $(pwd):/root -e DISPLAY=$DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix:ro debian:trixie
#set -e
PACKAGE="${1}"
OVERLAY_TMPFS_SIZE=4G

function usage
{
    echo "Usage: $0 <package dir>"
    exit 1
}

PACKAGE="$(realpath "${PACKAGE}")" 
if [ $# -ne 1 ] || [ ! -d "${PACKAGE}" ]; then
    usage
fi

function message
{
    echo
    echo -e "\e[93m${1}\e[m"
    return 0
}

function umount_dir
{
    local DIR="$1"
    while ! umount -R "${DIR}"; do
        message "Umounting ${DIR} failed, trying again in 1 second..."
        sleep 1 
    done &&\
    return 0
}
function interactive_chroot_install
{
    local PROMPT="$1"
    message "Starting bash session in /overlay/merged chroot..."
    chroot /overlay/merged /bin/bash --rcfile <(echo "PROMPT_COMMAND='history -a'"; echo "PS1='\u@${PROMPT} \w\$ '") -i
    message "Returned to the host from /overlay/merged..."
    if [ -f /overlay/merged/root/.bash_history ]; then
        cat /overlay/merged/root/.bash_history | grep -v "^exit"
        read -p "Append contents of .bash_history to overrides/install? [y/n] " reply
        [ "$reply" == "y" ] && cat /overlay/merged/root/.bash_history | grep -v "^exit" >> overrides/install
    fi
}
message "Setting up build container..."
apt-get update >/dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get -y install vim.tiny dialog fuse3 file make bubblewrap >/dev/null 2>&1
mkdir /overlay && mount -t tmpfs -o size=${OVERLAY_TMPFS_SIZE} tmpfs /overlay
mkdir /overlay/{base,package,work,merged}
# APPDIR ---------------------------------------------------------------------------------------------
cd "${PACKAGE}"
while true; do
    if [ -f overrides/APPDIR ]; then
        APPDIR="$(cat overrides/APPDIR)"
    else
        while true; do
            read -p "Use contents of /overlay/package [1] or /overlay/merged [2] as AppDir? " reply
            if [ "$reply" == "1" ]; then
                APPDIR="/overlay/package"
                break
            elif [ "$reply" == "2" ]; then
                APPDIR="/overlay/merged"
                break
            else
                echo "Incorrect reply: $reply"
            fi
        done
        echo "$APPDIR" > overrides/APPDIR
    fi

    [ -n "$AUTOMATIC" ] && break

    echo -n "APPDIR: "; cat overrides/APPDIR
    read -p "Is it what you want? [y/n] " reply
    [ "$reply" == "y" ] && break
    rm -f overrides/APPDIR
done
[ -n "$AUTOMATIC" ] && echo "Using APPDIR:" && cat overrides/APPDIR
# APPDIR ---------------------------------------------------------------------------------------------
# set_up_base ------------------------------------------------------------------------------------------------
message "Creating base..."
cd "${PACKAGE}"
while true; do
    if [ ! -f overrides/set_up_base ]; then
        # This could go into overrides/set_up_base
        #DEBIAN_FRONTEND=noninteractive apt-get install -y debootstrap >/dev/null 2>&1
        #debootstrap --variant=minbase trixie /overlay/base >/dev/null 2>&1

        echo "mount -o bind,ro / /overlay/base" > overrides/set_up_base
    fi

    [ -n "$AUTOMATIC" ] && break

    echo "set_up_base:"
    cat overrides/set_up_base
    read -p "Is it what you want? [y/n] " reply
    [ "$reply" == "y" ] && break
    message "Running subshell..."
    /bin/bash --rcfile <(echo "PS1='set_up_base> '") -i
done
[ -n "$AUTOMATIC" ] && echo "Using set_up_base:" && cat overrides/set_up_base
source overrides/set_up_base
# set_up_base ------------------------------------------------------------------------------------------------
mount -t overlay overlay -o userxattr,lowerdir=/overlay/base,upperdir=/overlay/package,workdir=/overlay/work /overlay/merged
mount --rbind /dev /overlay/merged/dev
mount --rbind /dev/pts /overlay/merged/dev/pts
mount --rbind /run /overlay/merged/run
mount --rbind /proc /overlay/merged/proc
mount --rbind /tmp /overlay/merged/tmp
# install ----------------------------------------------------------------------------------------------
message "Starting main installation..."
cd "${PACKAGE}"
mkdir /overlay/merged/package
mount --bind "${PACKAGE}" /overlay/merged/package
while true; do
    while true; do
        [ ! -f overrides/install ] && touch overrides/install

        [ -n "$AUTOMATIC" ] && break

        echo "install:"
        cat overrides/install
        read -p "Is it what you want? [y/n] " reply
        [ "$reply" == "y" ] && break
        interactive_chroot_install appimage
        message "Running subshell..."
        /bin/bash --rcfile <(echo "PS1='install> '") -i
    done
    [ -n "$AUTOMATIC" ] && echo "Using install:" && cat overrides/install
    chroot /overlay/merged /bin/bash /package/overrides/install
    [ $? -eq 0 ] && break
done
# install ----------------------------------------------------------------------------------------------
# cleanup --------------------------------------------------------------------------------------------
message "Cleaning up..."
cd "${PACKAGE}"
while true; do
    if [ ! -f overrides/cleanup ]; then
cat <<'OUTER' > overrides/cleanup
cat <<EOF | xargs rm -rf
root
etc/ld.so.cache
usr/share/doc
usr/share/lintian
var/log
var/cache
var/lib/dpkg
var/lib/apt
EOF
OUTER
    fi

    [ -n "$AUTOMATIC" ] && break

    echo "cleanup:"
    cat overrides/cleanup
    read -p "Is it what you want? [y/n] " reply
    [ "$reply" == "y" ] && break
    message "Running subshell..."
    /bin/bash --rcfile <(echo "PS1='cleanup> '") -i
done
[ -n "$AUTOMATIC" ] && echo "Using cleanup:" && cat overrides/cleanup
cd /overlay/merged
source package/overrides/cleanup
# cleanup --------------------------------------------------------------------------------------------
cd "${PACKAGE}"
if [ -z "$AUTOMATIC" ]; then
    message "Chroot /overlay/merged testing point reached"
    interactive_chroot_install testing_merged
fi

umount_dir /overlay/merged/package
rmdir /overlay/merged/package
umount_dir /overlay/merged/proc
umount_dir /overlay/merged/dev/pts
umount_dir /overlay/merged/dev
umount_dir /overlay/merged/run
umount_dir /overlay/merged/tmp

if [ -n "$AUTOMATIC" ]; then
    APPDIR="$APPDIR" make
else
    if [ "$APPDIR" == "/overlay/package" ]; then
        message "Umounting /overlay/merged..."
        umount_dir /overlay/merged
        find /overlay/package -type c -exec rm -rf {} \;

        message "Mounting back /overlay/merged with / as /overlay/base..."
        mount -o bind,ro / /overlay/base
        mount -t overlay overlay -o userxattr,lowerdir=/overlay/base,upperdir=/overlay/package,workdir=/overlay/work /overlay/merged
        mount --rbind /dev /overlay/merged/dev
        mount --rbind /dev/pts /overlay/merged/dev/pts
        mount --rbind /run /overlay/merged/run
        mount --rbind /proc /overlay/merged/proc
        mount --rbind /tmp /overlay/merged/tmp
        cd "${PACKAGE}"
        message "Chroot /overlay/package testing point reached"
        interactive_chroot_install testing_package
        umount_dir /overlay/merged/proc
        umount_dir /overlay/merged/dev/pts
        umount_dir /overlay/merged/dev
        umount_dir /overlay/merged/run
        umount_dir /overlay/merged/tmp
    fi
    [ -z "$AUTOMATIC" ] && APPDIR="$APPDIR" /bin/bash --rcfile <(echo "PS1='Set up Makefile (APPDIR=$APPDIR)> '") -i
fi

message "Umounting /overlay/merged..."
umount_dir /overlay/merged
umount_dir /overlay
rmdir /overlay
message "Exiting script..."
