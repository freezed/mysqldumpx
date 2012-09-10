#!/usr/bin/env bash

# Exit if some command returns with a non-zero status
set -e

# Fix path
export PATH=/bin:/usr/bin

# Determine full path to script
# http://stackoverflow.com/questions/59895/can-a-bash-script-tell-what-directory-its-stored-in
if [ -z "$MYSQLFILTERTABLES" ]; then
    HOMEDIR=$(cd "$(dirname "$0")" && pwd)
    MYSQLFILTERTABLES=$HOMEDIR/mysqlfiltertables.sh
fi

# List of required commands
REQUIRED_COMMANDS="
    basename
    comm
    dirname
    echo
    grep
    gzip
    logger
    mktemp
    mysql
    mysqldump
    pwd
    rm
    sed
    sort
    tail
    test
    xargs
"

# Record datestamp
DATESTAMP=$(date +"%Y-%m-%dT%H-%M-%S")

# Log message to stderr as well as syslog
log() {
    if [ -n "$DEBUG" ]; then
        logger -s -p user.notice -- "NOTE: $@"
    fi
}

# Log warning to stderr as well as syslog
warn() {
    logger -s -p user.info -- "WARNING: $@"
}

# Log error to stderr as well as syslog
err() {
    logger -s -p user.err -- "ERROR: $@"
}

# Check if a config file can be sourced without side effects
checkconfig() {
    # Test if this file is accessible
    test -f "$1" -a -r "$1" || return 1

    # Strip comments and whitespace, after that verify that only variable
    # assignements are left.
    if sed -e "s/#.*//" -e "/^[[:space:]]*$/d" "$1" | \
        grep -qiv "^ *[a-z_][a-z0-9_]\{1,\}=[a-z_0-9\"'_ =/:\.+<>~-]*$"; then
        return 1
    fi
}

# Read a configuration file and run the commands. This function must be
# executed in a subshell.
runconfig() {
    # Clear config variables which may not be inherited
    unset CONFDIR
    unset EXPAND
    unset DUMPFILE_ADD
    unset MYSQLDUMP_OPTS_ADD
    unset MYSQL_OPTS_ADD
    unset NAME

    # The following config variables are inheritable:
    # DATABASE
    # DUMPDIR
    # DUMPFILE
    # KEEP
    # MYSQLDUMP_OPTS
    # MYSQL_OPTS
    # TABLESET

    # Source configuration file
    source "$1"

    # Derive config-name from file name if necessary
    if [ -z "$NAME" ]; then
        NAME="$(basename "$1" .conf)"
    fi

    # Setup DUMPDIR, defaults to dirname of topmost config file
    DUMPDIR="${DUMPDIR:-$(cd "$(dirname "$1")" && pwd)}"

    # Construct basename
    DUMPFILE_ADD="${DUMPFILE_ADD:-$NAME}"
    if [ -n "$DUMPFILE" ]; then
        DUMPFILE="$DUMPFILE-$DUMPFILE_ADD"
    else
        DUMPFILE="$DUMPFILE_ADD"
    fi

    # Append additional mysql options if any
    if [ -n "$MYSQL_OPTS_ADD" ]; then
        MYSQL_OPTS="$MYSQL_OPTS $MYSQL_OPTS_ADD"
    fi
    if [ -n "$MYSQLDUMP_OPTS_ADD" ]; then
        MYSQLDUMP_OPTS="$MYSQLDUMP_OPTS $MYSQLDUMP_OPTS_ADD"
    fi

    # Setup CONFDIR, defaults to dirname of current config file
    CONFDIR="${CONFDIR:-$(cd "$(dirname "$1")" && pwd)}"

    # Change directory to configuration dir
    cd "$CONFDIR"

    if [ -n "$EXPAND" ]; then
        # Run the confset if this is not a simple config (recurse)
        log "Running confsets from $NAME"
        runconfigfiles $EXPAND
        log "Finish running confsets from $NAME"
    else
        log "Running config $NAME"
        # Take a backup using the current configuration
        if [ -z "DATABASE" ]; then
            warn "  Failed to run config $NAME. No database specified"
            return 1
        fi

        dumpfile="$DUMPDIR/$DUMPFILE-$DATESTAMP.sql.gz"
        log "  Dumping to file '$dumpfile'"
        if [ -n "$TABLESET" ]; then
            tables=$("$MYSQLFILTERTABLES" $MYSQL_OPTS "$DATABASE" < "$TABLESET")
            mysqldump $MYSQL_OPTS $MYSQLDUMP_OPTS "$DATABASE" $tables | gzip > "$dumpfile"
        else
            mysqldump $MYSQL_OPTS $MYSQLDUMP_OPTS "$DATABASE" | gzip > "$dumpfile"
        fi

        if [ "$KEEP" -gt "0" ]; then
            log "  Purging old dumps"
            purge "$DUMPDIR/$DUMPFILE-" ".sql.gz" $KEEP
        fi
        log "  Finish running config $NAME"
    fi
}

# Check and run the given configuration files
runconfigfiles() {
    for configfile in "$@"; do
        if checkconfig "$configfile"; then
            # Run in a subshell
            (runconfig "$configfile")
        else
            warn "Skipping invalid configfile '$configfile'"
        fi
    done
}

# Remove old backup files
purge() {
    prefix="$1"
    suffix="$2"
    keep="$3"

    files=$(ls -t1 -- "$prefix"*"$suffix")
    numfiles=$(echo "$files" | wc -l)
    if [ "$numfiles" -gt "$keep" ]; then
        echo "$files" | tail -n"$(($keep-$numfiles))" | xargs -d "\n" rm -f --
    fi
}


# Check for mysqlfiltertables helper script
if ! which "$MYSQLFILTERTABLES" > /dev/null; then
    err "Required script mysqlfiltertables.sh not found"
    exit 1
fi

# Check for required binaries
if ! which $REQUIRED_COMMANDS > /dev/null; then
    err "One or more of the required shell commands does is not available in your system"
    err "Required commands: $REQUIRED_COMMANDS"
    exit 1
fi

while getopts d opts; do
    case $opts in
        d) DEBUG='yes';;
        ?) exit 1;;
    esac
done

shift $(($OPTIND-1))

if [ "$#" -gt 0 ]; then
    # Run configfiles given on the command line if any
    runconfigfiles "$@"
    log "Done"
    exit
else
    # Otherwise check standard locations
    for f in "./mysqldumpx.conf" "~/mysqldumpx.conf" "/etc/mysqldumpx.conf"; do
        if [ -r "$f" ]; then
            runconfigfiles "$f"
            log "Done"
            exit
        fi
    done
fi

# If no config file was given and none was found, inform the user
err "No configuration file found. Either give one on the command line"
err "or place it into one of the standard locations: ./mysqldumpx.conf"
err "(next to mysqldumpx.sh), ~/mysqldumpx.conf or /etc/mysqldumpx.conf"
exit 1