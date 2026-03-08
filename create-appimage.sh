#!/bin/bash
#podman run -it --rm --privileged --volume $(pwd):/root debian:trixie
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
message "Setting up building container..."
apt-get update >/dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get -y install vim.tiny dialog fuse3 file make bubblewrap >/dev/null 2>&1
mkdir /overlay && mount -t tmpfs -o size=${OVERLAY_TMPFS_SIZE} tmpfs /overlay
mkdir /overlay/{base,package,work,merged}
message "Creating base..."
cd "${PACKAGE}"
while true; do
    if [ -f overrides/set_up_base ]; then
        function set_up_base
        {
            source overrides/set_up_base
        }
    else

        function set_up_base
        {
        #    DEBIAN_FRONTEND=noninteractive apt-get install -y debootstrap >/dev/null 2>&1 &&\
        #    debootstrap --variant=minbase trixie /overlay/base >/dev/null 2>&1 && SUFFIX="d"
            mount -o bind,ro / /overlay/base
        }
    fi

    [ -n "$AUTOMATIC" ] && break

    declare -f set_up_base
    read -p "Is it what you want? [y/n] " reply
    [ "$reply" == "y" ] && break
    message "Running subshell..."
    export -f set_up_base
    /bin/bash --rcfile <(echo "PS1='set_up_base> '") -i
done
set_up_base
mount -t overlay overlay -o userxattr,lowerdir=/overlay/base,upperdir=/overlay/package,workdir=/overlay/work /overlay/merged
mount --rbind /dev /overlay/merged/dev
mount --rbind /dev/pts /overlay/merged/dev/pts
mount --rbind /run /overlay/merged/run
mount --bind /proc /overlay/merged/proc
mount -t tmpfs tmpfs /overlay/merged/tmp
cd "${PACKAGE}"
while true; do
    if [ -f overrides/install ]; then
        function install
        {
            source overrides/install
        }
    else
        function install
        {
            return
        }
    fi

    [ -n "$AUTOMATIC" ] && break

    declare -f install
    read -p "Is overrides/install file ready? [y/n] " reply
    [ "$reply" == "y" ] && break
    message "Running shell in /overlay/merged..."
    chroot /overlay/merged /bin/bash --rcfile <(echo "PROMPT_COMMAND='history -a'"; echo "PS1='\u@appimage \w\$ '") -i
    message "Returned to the host from /overlay/merged..."
    if [ -f /overlay/merged/root/.bash_history ]; then
        cat /overlay/merged/root/.bash_history 
        read -p "Append contents of .bash_history to overrides/install? [y/n] " reply
        [ "$reply" == "y" ] && cat /overlay/merged/root/.bash_history >> overrides/install
    fi
    message "Running subshell..."
    export -f install
    /bin/bash --rcfile <(echo "PS1='install> '") -i
done
umount_dir /overlay/merged/proc
umount_dir /overlay/merged/dev/pts
umount_dir /overlay/merged/dev
umount_dir /overlay/merged/run
umount_dir /overlay/merged/tmp
message "Package contents are in /overlay/merged and /overlay/package now"
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

    echo "APPDIR is set to $(cat overrides/APPDIR)"
    read -p "Is it what you want? [y/n] " reply
    [ "$reply" == "y" ] && break
    rm -f overrides/APPDIR
done
message "Cleaning up..."
cd "${PACKAGE}"
while true; do
    if [ -f overrides/cleanup ]; then
        function cleanup
        {
            source overrides/cleanup
        }
    else
        function cleanup
        {
            cd /overlay/merged
            rm -rf \
            root \
            etc/ld.so.cache \
            usr/share/doc \
            usr/share/lintian \
            var/log \
            var/cache \
            var/lib/dpkg \
            var/lib/apt
        }
    fi

    [ -n "$AUTOMATIC" ] && break

    declare -f cleanup
    read -p "Is it what you want? [y/n] " reply
    [ "$reply" == "y" ] && break
    message "Running subshell..."
    export -f cleanup
    /bin/bash --rcfile <(echo "PS1='cleanup> '") -i
done
cleanup
cd "${PACKAGE}"
if [ "$APPDIR" == "/overlay/merged" ]; then
    if [ -n "$AUTOMATIC" ]; then
        APPDIR="$APPDIR" make
    else
        /bin/bash --rcfile <(echo "PS1='finalize (merged)> '") -i
    fi
fi
cd "${PACKAGE}"
umount_dir /overlay/merged
message "Package contents are in /overlay/package now"
find /overlay/package -type c -exec rm -rf {} \;
if [ "$APPDIR" == "/overlay/package" ]; then
    if [ -n "$AUTOMATIC" ]; then
        APPDIR="$APPDIR" make
    else
        bin/bash --rcfile <(echo "PS1='finalize (package)> '") -i
    fi
fi
umount_dir /overlay
message "Exiting script..."
