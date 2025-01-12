#!/bin/sh
# Wiki.sh - shell/awk-interface to mediawiki
# Copyright (C) 2010 Redpill Linpro AS
# Copyright (C) 2010 Kristian Lyngstol
# Author: Kristian Lyngstøl <kristian@bohemians.org>
#
# Additonal contributions by:
# Vegard Haugland <vegard@haugland.at>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

################
# "Global variables" that are not really affected by configuration
################

TIM=$(date +%s)
ME=$(basename $0)
ACTION=""
PAGE=""
CONFIGDIR=~/.config
CONFIGNAME=wikish.conf

writeconfig()
{
    CONFIG=${CONFIGDIR}/${CONFIGNAME}
    if [ -e ${CONFIG} ]; then
        return
    fi
    if [ ! -d ${CONFIGDIR} ]; then
        mkdir ${CONFIGDIR}
    fi
    cat > $CONFIG << _EOF_
#!/bin/sh

# Avoid trashing \$PWD by using a tmp dir:
#cd /home/kristian/tmp/wiki
# (now THAT'S simple)

# Protocol to use (http or https)
PROTO="http"

# Hostname(+port)
HOST="localhost"

# ScriptPath
#
# Example:
# http://path.to/w/index.php?title=Somepage&action=raw
# where ScriptPath is "/w/index.php?title="
SCRIPTPATH="/w/index.php?title="

# API-url, with trailing ?
#
# Example (works for wiki.varnish-software.com):
API="w/api.php?"

# Example (works for wiki.redpill-linpro.com):
# API="api.php?"

USER="username"

# Feel free to replace this with something smarter
echo password:
read -s PASSWORD

# Like:
# PASSWORD=password
# or: 
# PASSWORD=\$(gpg --decrypt ~/Documents/Passwords/wikipw)
# ... you get the point. It's a shell script.
_EOF_

cat << _EOF_
Note:

A config file has been written to ~/.config/wikish.conf.
Make the necessary changes, and run this script again.
_EOF_
exit 1
}

# Should probably >&2
usage()
{
    cat <<_EOF_
On a happier note:

Configure stuff in wikish.config, then: 
 ./wiki.sh GET Some_Page
 ./wiki.sh POST Some_Page
 ./wiki.sh LIST Som*
 ./wiki.sh EDIT Some_Page
 ./wiki.sh CLEAN
(Any trailing .wiki in the page-name is stripped)

wiki.sh will (hopefully) not overwrite anything, but back it up for you.

Configurations can be local (.wikish.config) or global (typically
~/.config/wikish.config). See README for details.

Oh yeah, and so far wikish only supports basic http auth
... and no conflict-handling.
_EOF_
}

debug() {
    if [ -z "$DEBUG" ]; then
        true;
    else
        echo $*
    fi
}

################
# Configuration
################
#
# Does config file exist? If not, create one.
writeconfig

if [ -e "${CONFIGDIR}/${CONFIGNAME}" ]; then
    test -f $CONFIGDIR/$CONFIGNAME && . ${CONFIGDIR}/${CONFIGNAME}
else
    echo "Config file not found. This should not happen..."
    exit
fi

# Check that the required variables are set in the config file
if [ -z "$API" ] || [ -z "$USER" ] || [ -z "$HOST" ] || \
    [ -z "$PASSWORD" ] || [ -z "$PROTO" ] || [ -z "$SCRIPTPATH" ]; then
    echo "Insufficient or missing configuration."
    exit 1;
fi

# Read local config
test -f $PWD/.${CONFIGNAME} && . $PWD/.${CONFIGNAME}

###############
# How do we perform a GET request on a HTML page from the terminal?
###############
if [ -x /usr/bin/GET ];
then
    GETCMD=GET
elif [ -x /usr/bin/lynx ];
then
    GETCMD=lynx
fi

################
# Sym-link and argument mapping
################

if [ $ME = "wikiedit" ]; then
    ACTION="EDIT"
    PAGE=$1
elif [ $ME = "wikiget" ]; then
    ACTION="GET"
    PAGE=$1
elif [ $ME = "wikipost" ]; then
    ACTION="POST"
    PAGE=$1
elif [ $ME = "wikilist" ]; then
    ACTION="LIST"
    PAGE=$1
else
    ACTION=$1
    PAGE=$2
fi


if [ -z "$PAGE" ] && [ ! "x$1" = "xCLEAN" ]; then
    usage;
    exit 1;
fi

# Allows for Main_Page and Main_Page.wiki - ie: tab completion.
PAGE=$(echo $PAGE | sed s/.wiki$//);

# Cheat-code for awesome: Allows wikiedit Customer/Foo etc.
mkdir -p `dirname "${PAGE}"`

# Gets $PAGE and stores it to $PAGE.wiki
# Safely backs up any existing $PAGE.wiki to $PAGE.wiki.$TIM
getit()
{
    if [ -f "$PAGE.wiki" ]; then
        debug "Moving $PAGE.wiki to $PAGE.wiki.$TIM"
        if [ -f $PAGE.wiki.$TIM ]; then
            echo "PANIC! already exist. Stop using loops!";
            sleep 5;
            exit 1;
        fi
        mv "$PAGE.wiki" "$PAGE.wiki.$TIM"
    fi

    # Configure GETCMD according to available tools
    case "$GETCMD" in
      "GET")
        GET "${PROTO}://${USER}:${PASSWORD}@${HOST}${SCRIPTPATH}${PAGE}&action=raw" > "$PAGE.wiki"
      ;;
      "lynx")
        lynx -dump -auth "${USER}:${PASSWORD}" "${HOST}${SCRIPTPATH}${PAGE}&action=raw" > "$PAGE.wiki"
      ;;
    esac

    if [ $? = 0 ]; then
        debug "$PAGE.wiki created seemingly without errors! Phew.";
    else
        echo "$PAGE.wiki GET-operation may have blown apart.  Abandon ship!"
        exit 2;
    fi
}

# Connects to api.php and attempts to list pages with name given.
listit()
{
     BURL="${PROTO}://${USER}:${PASSWORD}@${HOST}/${API}"
     # in case the user lists "a*", remove "*"
     PAGE=$( echo $PAGE | sed 's/*//g')
     curl -s "${BURL}action=query&list=allpages&format=txt&aplimit=50&apprefix=${PAGE}" \
         | grep title | sed 's#.*=> \(.*\)#\1#;s# #_#g'
}

# Gets an edittoken and session for editing $PAGE and posts the local
# $PAGE.wiki. Note that the awk-script generates a curl-command which is
# piped to sh. Not terribly pretty.
postit()
{
    # Check if the file is UTF-8. If so, convert to ASCII.
    # If we send a UTF-8 encoded file to the MediaWiki API, the wiki syntax
    # will not be parsed and the browser will display the raw wiki text in a
    # neat (unparsed) oneliner.

    if [ -n "$( file $PAGE.wiki | grep "UTF-8" )" ]; then
        awk '{if(NR==1)sub(/^\xef\xbb\xbf/,"");print}' $PAGE.wiki > $PAGE.wiki.fixed
        mv $PAGE.wiki.fixed $PAGE.wiki
    fi

     BURL="${PROTO}://${USER}:${PASSWORD}@${HOST}/${API}"
    # Welcome to the school of funky shell-nesting.
    {    
         curl -s -c cookie.jar "${BURL}action=query&format=txt&prop=info&intoken=edit&title=$PAGE&titles=$PAGE" | awk -v page="$PAGE" -v burl="$BURL" '
        BEGIN {
            edittoken="";
        }
        /\[edittoken\] => / {
            edittoken = $3;
        }
        END {
            gsub("\\\\","\\\\",edittoken);
            gsub("+","%2B",edittoken);
            title=page
            gsub(" ","%20",title);
            printf "echo | curl -s --post301 -k --data-urlencode \"text@"
            printf "%s.wiki\" ", page;
            printf "-b cookie.jar";
            printf " \"" burl "format=txt&action=edit&title=%s&titles=%s&token=%s\" \n", title, title, edittoken
        }
        ' | sh
        if [ ! $? = "0" ]; then
            echo "Failed to push. curl returned non-zero" >&2;
            exit 1;
        fi
    } | egrep '(result|title)'
}


################
# "Proper" execution starts here
################

if [ "x$ACTION" = "xGET" ]; then
    getit
elif [ "x$ACTION" = "xPOST" ]; then
    postit
elif [ "x$ACTION" = "xLIST" ]; then
    listit
elif [ "x$ACTION" = "xEDIT" ]; then
    getit
    cp "$PAGE.wiki" "$PAGE.wiki.original.$TIM"
    # Thank Red Hat for the non-vi-clone support: they keep /bin/vi
    # bastardized so you need/want to run 'vim' explicitly. Otherwise
    # there would be no reason to support other editors.
    if [ -z "$EDITOR" ]; then
        vi "$PAGE.wiki"
    else
        $EDITOR "$PAGE.wiki"
    fi
    diff -q "$PAGE.wiki" "$PAGE.wiki.original.$TIM" >/dev/null && {
        echo "Unchanged - not pushing it."
        exit 1;
    }
    postit
elif [ "x$ACTION" = "xCLEAN" ]; then
    # Generate too much crap. One day I will put it in dot-files.
    RMS=*.wiki.*[0-9]*
    echo $RMS
    echo "Shall I kill the above files?"
    echo "[Y]es/No!"
    read yesno
    if [ -z "$yesno" ] || [ "$yesno" = "Y" ] || [ "$yesno" = "y" ] || [ "x$yesno" = "xyes" ]; then
        rm $RMS && echo "Done"
    else
        echo "Bailing!";
    fi
else
    echo "Unknown arguments" >&2
    usage
fi
