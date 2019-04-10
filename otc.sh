#!/bin/bash
# vi:set ts=3 sw=3:
# == Module: Open Telekom Cloud CLI 0.8.x
#
# Manage OTC via Command Line
#
# Provides a shell/curl/jq based alternative to the
# python-openstackclient tools, exposing a lot o standard OpenStack functions
# as well as some custom OTC interfaces.
#
# === Parameters
#
# === Variables
#
# Recognized variables from environment:
#
# BANDWIDTH
#  set to default value "25" if unset
# VOLUMETYPE
#  set to default value "SATA" if unset
# APILIMIT
#  Either an integer, limiting the number of API results per call, or "off", removing limits.
#  If unset, default limits are used (different among API calls), can be overridden by --limit NNN.
# MAXGETKB
#  The maximum size for API (GET) response size that the API gateway allows without cutting it
#  if off (and thus breaking it for https). otc.sh tries to auto-paginate here ...
#
# ... and the standard OS_ variables that you also need for the OpenStack python tools
# If unset, these are looked for in standard places
# ~/.ostackrc.$OTC_TENANT, ~/.ostackrc, ~/novarc, ~/openrc
#
# === Examples
#
# Examples
# See help ...
#
# === Authors
#
# Zsolt Nagy <Z.Nagy@t-systems.com>
# Kurt Garloff <t-systems@garloff.de>
# Christian Kortwich <christian.kortwich@t-systems.com>
#
# === Copyright
#
# Copyright 2016 - 2017 T-Systems International GmbH
# License: CC-BY-SA-4.0
#
[ "$1" = -x ] && shift && set -x

VERSION=0.8.32

# Get Config ####################################################################
warn_too_open()
{
	PERM=$(stat -Lc "%a" "$1")
	if test "${PERM:2:1}" != "0"; then
		echo "#Warning: $1 permissions too open ($PERM)" 1>&2
	fi
}

may_read_env_files()
{
	for file in "$@"; do
		if test -r "$file"; then
			echo "#Note: Reading environment from $file ..." 1>&2
			source "$file"
			warn_too_open "$file"
			if test -n "$OS_PASSWORD" -a -n "$OS_USERNAME"; then break; fi
		fi
	done
}

otc_dir="$(dirname "$0")"
# Parse otc-tools specific config file (deprecated)
if test -r ~/.otc_env.sh; then
	source ~/.otc_env.sh
	warn_too_open ~/.otc_env.sh
#else
#	echo "#Note: No ~/.otc_env.sh found, no defaults for ECS creation" 1>&2
fi
# Parse standard OpenStack environment setting files if needed
if test -z "$OS_PASSWORD" -o -z "$OS_USERNAME"; then
	may_read_env_files ~/.ostackrc.$OTC_TENANT ~/.ostackrc ~/.novarc ~/novarc
fi
# Defaults
if test -z "$OS_USER_DOMAIN_NAME"; then
	export OS_USER_DOMAIN_NAME="${OS_USERNAME##* }"
fi
if test -n "$OS_AUTH_URL"; then
	REG=${OS_AUTH_URL#*://}
	REG=${REG#*.}
	if test -z "$OS_REGION_NAME"; then
		export OS_REGION_NAME=${REG%%.*}
	fi
	#echo "OS_REGION_NAME: $OS_REGION_NAME"
	#REG=${REG#*.}
	export OS_CLOUD_ENV=${REG%%.*}
fi
if test -z "$OS_PROJECT_NAME"; then
	if test -n "$OS_TENANT_NAME"; then
   	export OS_PROJECT_NAME="$OS_TENANT_NAME"
	else
		export OS_PROJECT_NAME="$OS_REGION_NAME"
	fi
fi
if test -z "$MAXGETKB"; then
	export MAXGETKB=251
fi
# S3 environment
if test -z "$S3_ACCESS_KEY_ID" -a -r ~/.s3rc.$OTC_TENANT; then
	echo "#Note: Reading S3 environment from ~/.s3rc.$OTC_TENANT ..." 1>&2
	source ~/.s3rc.$OTC_TENANT
	warn_too_open ~/.s3rc.$OTC_TENANT
fi
if test -z "$S3_ACCESS_KEY_ID" -a -r ~/.s3rc; then
	echo "#Note: Reading S3 environment from ~/.s3rc ..." 1>&2
	source ~/.s3rc
	warn_too_open ~/.s3rc
fi
# Alternatively parse CSV as returned by OTC
if test -r ~/credentials-$OTC_TENANT.csv; then
	CRED=credentials-$OTC_TENANT.csv
else
	CRED=credentials.csv
fi
if test -z "$S3_ACCESS_KEY_ID" -a -r ~/$CRED; then
	echo -n "#Note: Parsing S3 $CRED ... " 1>&2
	LN=$(tail -n1 ~/$CRED | sed 's/"//g')
	UNM=${LN%%,*}
	LN=${LN#*,}
	if test "$UNM" = "$OS_USERNAME"; then
		echo "succeeded" 1>&2
		export S3_ACCESS_KEY_ID="${LN%,*}"
		export S3_SECRET_ACCESS_KEY="${LN#*,}"
	else
		echo "user mismatch \"$UNM\" != \"$OS_USERNAME\"" 1>&2
	fi
	warn_too_open ~/$CRED
fi

# ENVIRONMENT SETTINGS ####################################################################
unset FLAVORSET

# Defaults
if test -z "$BANDWIDTH"; then BANDWIDTH=25; fi
if test -z "$VOLUMETYPE"; then
	if [[ "$INSTANCE_TYPE" == e1.* ]] || [[ "$INSTANCE_TYPE" == e2.* ]] || [[ "$INSTANCE_TYPE" == hl1.* ]]; then
		#VOLUMETYPE=co-p1
		VOLUMETYPE="uh-l1"
	else
		VOLUMETYPE="SATA"
	fi
fi

test -n "$S3_HOSTNAME" || export S3_HOSTNAME=obs.otc.t-systems.com

if test -n "$OS_AUTH_URL"; then
	if [[ "$OS_AUTH_URL" = *"/v3" ]]; then
		export IAM_AUTH_URL="$OS_AUTH_URL/auth/tokens"
	else
		export IAM_AUTH_URL="$OS_AUTH_URL/tokens"
	fi
else
	export IAM_AUTH_URL="https://iam.${OS_REGION_NAME}.otc.t-systems.com/v3/auth/tokens"
fi

if test -z "$TMPDIR"; then TMPDIR=/dev/shm; fi
if test ! -d "$TMPDIR"; then TMPDIR=/tmp; fi

PRIMARYDNS=${PRIMARYDNS:-100.125.4.25}
SECDNS=${SECDNS:-9.9.9.9}

# REST call curl wrappers ###########################################################

# Output HTML
dumphtml()
{
	echo "$@" | sed 's/<[^>]*>//g'
}

is_html()
{
	echo "$1" | grep '<[hH][tT][mM][lL]' 2>&1 >/dev/null
}

is_html_err()
{
	if ! is_html "$1"; then return 1; fi
	echo "$1" | grep '<[tT][iT][tT][lL][eE]> *[45][012][0-9] [A-Z]' 2>&1 >/dev/null
}

uriencodenoteq()
{
	local OUT
	OUT="${*//%/%25}"
	OUT="${OUT// /%20}"
	OUT="${OUT//\?/%3F}"
	OUT="${OUT//&/%26}"
	OUT="${OUT//\"/%22}"
	OUT="${OUT//\//%2F}"
	OUT="${OUT//,/%2C}"
	OUT="${OUT//;/%3B}"
	OUT="${OUT//!/%21}"
	OUT="${OUT//:/%3A}"
	OUT="${OUT//\#/%23}"
	echo "$OUT"
}

uriencode()
{
	OUT="$(uriencodenoteq $*)"
	OUT="${OUT//=/%3D}"
	echo "$OUT"
}

hashtoken()
{
	while read ln; do
		if ! echo "$ln" | grep '\-Token' >/dev/null 2>&1; then continue; fi
		echo "$ln" | sed 's@^.*\-Token: MII\([^ ]*\).*$@MII\1@g' | md5sum | awk '{ print $1; }'
		#if test ${PIPESTATUS[1]} != 0; then echo "ERROR IN SED" 1>&2; exit 2; fi
	done
}

# Generic wrapper to facilitate debugging
docurl()
{
	local ANS RC TMPHDR
	# TODO: Alternatively use -w "%{http_code}\n"
	TMPHDR=`mktemp $TMPDIR/curlhdr.$$.XXXXXXXXXX`
	#TMPHDR=`mktemp -u $TMPDIR/curlhdr.$$.XXXXXXXXXX`
	#mkfifo -m 0600 "$TMPHDR"
	if test -n "$DEBUG"; then
		TKNDEB=$(echo "$@" | hashtoken)
		echo "#DEBUG: docurl $INS $@" | sed -e "s/-Token: MII[^ ]*/-Token: MII$TKNDEB/g" -e 's/"password": "[^"]*"/"password": "SECRET"/g' 1>&2
		if test "$DEBUG" = "2"; then
			ANS=`curl $INS -D $TMPHDR "$@"`
			RC=$?
			TKNDEB=$(cat $TMPHDR | hashtoken)
			echo -n "#DEBUG: Header" 1>&2
			cat $TMPHDR  | sed "s/X-Subject-Token: MII.*\$/X-Subject-Token: MII$TKNDEB/" 1>&2
		else
			ANS=`curl $INS -D $TMPHDR "$@"`
			RC=$?
		fi
		TKNDEB=$(echo "$ANS" | hashtoken)
		echo "#DEBUG: ($RC) $ANS" | sed "s/X-Subject-Token: MII.*\$/X-Subject-Token: MII$TKNDEB/" 1>&2
		#echo "$ANS"
	else
		ANS=`curl $INS -D $TMPHDR "$@"`
		RC=$?
		#echo "$ANS"
	fi
	HDRCODE=$(cat "$TMPHDR" | head -n1 | grep '^HTTP')
	HDRCODE=$(echo "$HDRCODE" | sed 's/^HTTP\/[0-9.]* \([0-9]*\) .*$/\1/')
	#echo "$HDRCODE" 1>&2
	CODE=$HDRCODE
	rm $TMPHDR
	if test $RC != 0; then echo "$ANS" 1>&2; return $RC
	else
		# Sometimes function is called with '-i' and the response contains HTTP headers
		# For a proper response processing get the pure BODY
		local BODY HDR2 CODE2 JBODY ERROR ECODE MSG
		HDR=$(echo "$ANS" | head -n1 | grep '^HTTP')
		if test -n "$HDR"; then
			# strip off headers on the first empty string. It is still not 100% solution,
			# but there is no way to access CURLOPT_HEADERFUNCTION from bash
			# OS X sed seems to be not handling \r \s correctly, so one with printf should be added
			BODY=$(echo "$ANS" | sed "1,/^\s*$(printf '\r')*$/d")
		else
			BODY=$ANS
		fi
		HDR2=$(echo "$BODY" | head -n1 | grep '^HTTP')
		CODE2=$(echo "$HDR2" | sed 's/^HTTP\/[0-9.]* \([0-9]*\) .*$/\1/')
		if is_html_err "$BODY"; then
			dumphtml "$BODY" 1>&2; return 9
		fi
		if echo "$BODY" | grep '{' >/dev/null; then JBODY="{${BODY#*\{}"; else JBODY=""; fi
		ERROR=$(echo "$JBODY" | jq '.error' 2>/dev/null | tr -d '"')
		if test "$ERROR" != "null" -a -z "$QUIETERR"; then echo "$ERROR" 1>&2; fi
		CODE=$(echo "$JBODY"| jq '.code' 2>/dev/null)
		ECODE=$(echo "$JBODY"| jq '.error.error_code' 2>/dev/null)
		if test "$CODE" == "null"; then
			CODE=$(echo "$JBODY"| jq '.[] | .code' 2>/dev/null)
			if test "${CODE:0:4}" == "null" -o "${CODE:0:2}" == "[]"; then CODE=""; fi
		fi
		#echo -e "docurl DEBUG: HDR=$HDR\nHDR2=$HDR2\nBODY=$BODY\nERROR=$ERROR\nCODE=$CODE\nECODE=$ECODE" 1>&2 
		#if test -z "$CODE" -o "$CODE" == "null" && test "$ECODE" != "null"; then CODE="$ECODE"; fi
		if test "$INDMS" != 1; then
			MSG=$(echo "$JBODY"| jq '.message' 2>/dev/null)
			TYP=$(echo "$JBODY"| jq '.type' 2>/dev/null)
			DET=$(echo "$JBODY"| jq '.detail' 2>/dev/null)
			if echo "$MSG" | grep "Token need to refresh" >/dev/null 2>&1 && test -z "$INAUTH"; then
				echo "#Note: $MSG -> Retry" 1>&2
				local OLDDC=$DISCARDCACHE
				DISCARDCACHE=1
				if test -n "$PRJ_ID_UNSET"; then unset OS_PROJECT_ID; fi
				getIAMToken $REQSCOPE || exit $?
				DISCARDCACHE=$OLDDC
				declare -a ARGS
				for a in "$@"; do ARGS[${#ARGS[@]}]=$(echo $a | sed "s/Token: MII[^ ]*/Token: $TOKEN/"); done
				docurl "${ARGS[@]}"
				return
			fi
			if test -n "$MSG" -a "$MSG" != "null"; then 
				if test -z "$QUIETERR"; then echo "ERROR ${CODE}: $MSG $TYP $DET" | tr -d '"' 1>&2; fi
				return 9
			fi
			MSG=$(echo "$ANS"| jq '.[] | .message' 2>/dev/null)
			TYP=$(echo "$ANS"| jq '.[] | .type' 2>/dev/null)
			DET=$(echo "$ANS"| jq '.[] | .detail' 2>/dev/null)
			if test -n "$MSG" -a "${MSG:0:4}" != "null" -a "${MSG:0:2}" != "[]"; then echo "ERROR[] ${CODE}: $MSG $TYP $DET" | tr -d '"' 1>&2; return 9; fi
			if test -n "$ECODE" -a "$ECODE" != "null"; then RC=9; fi
		fi
		# PUT/HEAD only return an HTTP header
		if test -n "$CODE" && test "$CODE" -ge 400; then RC=9; echo "$HDR" | sed 's/^HTTP\/[0-9.]* //' 1>&2; fi
		if test -n "$CODE2" && test "$CODE2" -ge 400; then RC=9; echo "$HDR2" | sed 's/^HTTP\/[0-9.]* //' 1>&2; fi
		HDR=$(echo "$ANS" | head -n1 | grep '^HTTP')
		CODE=$(echo "$HDR" | sed 's/^HTTP\/[0-9.]* \([0-9]*\) .*$/\1/')
		if test -n "$CODE" && test "$CODE" -ge 400; then echo "${HDR#* }" 1>&2; RC=9; fi
	fi
	echo "$ANS"
	#echo "docurl Return code: $RC" 1>&2
	return $RC
}

curlpost()
{
	docurl -i -sS -H "Content-Type: application/json" -d "$@"
}

curlhead()
{
	docurl -I -sS -X HEAD -H "Content-Type: application/json" -H "Accept: application/json" "$@"
}

curlpostauth()
{
	TKN="$1"; shift
	docurl -sS -X POST \
		-H "Content-Type: application/json" \
		-H "Accept: application/json" \
		-H "X-Auth-Token: $TKN" \
		-H "X-Language: en-us" \
		-d "$@"
}

curlputauth()
{
	TKN="$1"; shift
	if test -n "$1"; then
		docurl -sS -X PUT -H "Content-Type: application/json" -H "Accept: application/json" \
			-H "X-Auth-Token: $TKN" -d "$@"
	else
		docurl -sS -X PUT -H "Content-Type: application/json" -H "Accept: application/json" \
			-H "X-Auth-Token: $TKN" "$@"
	fi
}

curlputauthbinfile()
{
	TKN="$1"; shift
	docurl -sS -X PUT -H "Content-Type: application/octet-stream" \
		-H "X-Auth-Token: $TKN" -T "$@"
}

curlgetauth()
{
	TKN="$1"; shift
	docurl -sS -X GET -H "Content-Type: application/json" -H "Accept: application/json" \
		-H "X-Auth-Token: $TKN" -H "X-Language: en-us" "$@"
}

curlheadauth()
{
	TKN="$1"; shift
	docurl -sS -X HEAD --head -H "X-Auth-Token: $TKN" "$@"
}

curlheadauthparm()
{
	TKN="$1"; shift
	URL="$1"; shift
	docurl -sS -X HEAD --head -H "Content-Type: application/json" -H "X-Auth-Token: $TKN" "$@" "$URL"
}

curlgetauth_pag()
{
	local URL="$2" HASLIM HASPAR LIM TMPF MARKPAR NOANS LASTNO
	unset HASLIM
	echo "$URL" | grep -q  'limit=' && HASLIM=1
	#echo "$HASLIM $MAXGETKB $RECSZ" 1>&2
	if test -n "$HASLIM" -o -z "$MAXGETKB" -o "$MAXGETKB" == "off" -o -z "$RECSZ"; then curlgetauth "$@"; return; fi
	TKN="$1"
	unset HASPAR
	echo "$URL" | grep -q '?' && HASPAR=1
	#RECSZ, HDRSZ, ARRNM, IDFIELD
	LIM=$((($MAXGETKB*1024-$HDRSZ)/$RECSZ))
	if test "$HASPAR" == 1; then
		LIMPAR="&limit=$LIM"
	else
		LIMPAR="?limit=$LIM"
	fi
	TMPF=$(mktemp $TMPDIR/otc.sh.$$.XXXXXXXX)
	MARKPAR=""
	NOANS=0; LASTNO=1
	local RC=0
	while test $NOANS != $LASTNO -a $(($NOANS%$LIM)) == 0; do
		LASTNO=$NOANS
		docurl -sS -X GET -H "Content-Type: application/json" -H "Accept: application/json" \
			-H "X-Auth-Token: $TKN" -H "X-Language: en-us" "$URL$LIMPAR$MARKPAR" >>$TMPF
		# Remember error
		RV=$?
		# TODO: Handle 413 => halve page size
		if test $RC == 0 -a $RV != 0; then RC=$RV; fi
		# TODO: Actually, look for _links next pointer
		local ANS=$(cat $TMPF | jq -r ".${ARRNM}[] | .${IDFIELD}")
		NOANS=$(echo "$ANS" | wc -l)
		LAST=$(echo "$ANS" | tail -n1 | tr -d '"')
		MARKPAR="&marker=$LAST"
	done
	cat $TMPF
	rm $TMPF
	return $RC
}

curldeleteauth()
{
	TKN="$1"; shift
	URL="$1"; shift
	if test -n "$2"; then
		HDR="$1"; shift
		#docurl -sS -X DELETE -H "Content-Type: application/json" -H "Accept: application/json" -H "$HDR" -H "X-Auth-Token: $TKN" "$URL" "$@"
		docurl -sS -X DELETE -H "Accept: application/json" -H "$HDR" -H "X-Auth-Token: $TKN" "$URL" "$@"
	else
		#docurl -sS -X DELETE -H "Content-Type: application/json" -H "Accept: application/json" -H "X-Auth-Token: $TKN" "$URL" "$@"
		docurl -sS -X DELETE -H "Accept: application/json" -H "X-Auth-Token: $TKN" "$URL" "$@"
	fi
}

curldeleteauth_language()
{
	TKN="$1"; shift
	docurl -sS -X DELETE \
		-H "Content-Type: application/json" \
		-H "Accept: application/json" \
		-H "X-Language: en-us" \
		-H "X-Auth-Token: $TKN" "$@"
}

curlpatchauth()
{
	TKN="$1"; shift
	if test -z "$3"; then CTYPE="application/json"; else CTYPE="$3"; fi
	docurl -sS -X PATCH \
		-H "Content-Type: $CTYPE" \
		-H "Accept: application/json" \
		-H "X-Auth-Token: $TKN" \
		-d "$@" 
}

# ARGS: TKN URL PATH OP VALUE [CONTENTTYPE]
curldopatch()
{
	TKN="$1"; shift
	#if test -z "$4"; then OP="remove"; else OP="$3"; VAL="\"value\": \"$4\", "; fi
	if test "$3" != "remove"; then VAL="\"value\": \"$4\", "; fi
	if test -z "$5"; then CTYPE="application/json"; else CTYPE="$5"; fi
	curlpatchauth "$TKN" "[{\"path\": \"$2\", $VAL\"op\": \"$3\"}]" "$1" "$CTYPE"
}

# ARGS: TKN URL PATH VALUE [CONTENTTYPE]
curladdorreplace()
{
	TKN="$1"; shift
	local VAL
	if test -z "$4"; then CTYPE="application/json"; else CTYPE="$4"; fi
	VAL=$(curlgetauth "$TKN" "$1" | jq ".$2"; return ${PIPESTATUS[0]})
	echo "#DEBUG: /$2: $VAL -> $3" 1>&2
	if test "$VAL" = "null"; then
		if test -z "$3"; then
			echo "WARN: Nothing to do, /$2 already non-existent" 1>&2
		else
			curldopatch "$TKN" "$1" "/$2" "add" "$3" "$CTYPE"
		fi
	else
		if test -z "$3"; then
			curldopatch "$TKN" "$1" "/$2" "remove" "" "$CTYPE"
		else
			curldopatch "$TKN" "$1" "/$2" "replace" "$3" "$CTYPE"
		fi
	fi
}

curldeleteauthwithjsonparameter()
{
	# $1: TOKEN
	# $2: PARAMETER
	# $3: URI
	TKN="$1"; shift
	docurl -sS -X DELETE \
		-H "Content-Type: application/json" \
		-H "X-Language: en-us" \
		-H "X-Auth-Token: $TKN" -d "$@" | jq '.'
}

unset SUBNETAZ

##########################################################################################

#FUNCTIONS ###############################################################################

# Helper to remove unnecessary trailing , in JSON (before })
rmvCommaJSON()
{
	# Remove trailing , even w/o '}'
	CLBR=$2
	STR="$1"
	LF="
"
	TB=$(echo -e "\t")
	declare -i LN=${#STR}
	declare -i CI=$LN
	while test $CI -gt 0; do
		let CI-=1
		CHR="${STR:$CI:1}"
		if test "$CHR" == "}"; then CLBR=1; continue; fi
		if test "$CHR" == "$LF" -o "$CHR" == " " -o "$CHR" == "$TB"; then continue; fi
		if test $CLBR == 1 -a "$CHR" == ","; then
			let LN-=1
			STR="${STR:0:$CI}${STR:$((CI+1)):$((LN-CI))}"
			continue
		fi
		CLBR=0
	done
	echo "$STR"
}

# Arguments CATALOGJSON SERVICETYPE
getcatendpoint()
{
	local SERVICE_EP=$(echo "$1" | jq "select(.type == \"$2\") | .endpoints[].url" | tr -d '"')
	if test "$SERVICE_EP" != "null"; then
		echo "$SERVICE_EP"
	fi
}

# Arguments: SERVICESJSON ENDPOINTSJSON SERVICETYPE PROJECTID
getendpoint()
{
	local SERVICE_ID=$(echo "$1" | jq ".services[] | select(.type == \"$3\" and .enabled == true) | .id")
	if test -z "$SERVICE_ID"; then return; fi
	local SERVICE_EP=$(echo "$2" | jq ".endpoints[] | select(.service_id == $SERVICE_ID and .region == \"$OS_REGION_NAME\") | .url" | tr -d '"' | sed -e "s/\$(tenant_id)s/$4/g")
	echo "$SERVICE_EP"
}

# Arguments SERVICEJSON SERVICETYPE
getv2endpoint()
{
	local SERVICE_EP=$(echo "$1" | jq ".access.serviceCatalog[] | select(.type == \"$2\") | .endpoints[].publicURL" | tr -d '"')
	if test "$SERVICE_EP" != "null"; then
		echo "$SERVICE_EP"
	fi
}

# Token caching ...
IAMTokenFilename()
{
	# We don't need OS_REGION_NAME, as it's contained in the PROJECT.
	local FN="${OS_USERNAME% *}"
	if test "$REQSCOPE" != "unscoped"; then FN="$FN.$OS_USER_DOMAIN_NAME"; fi
	local PRJ=$OS_PROJECT_ID
	if test -z "$PRJ"; then PRJ="$OS_PROJECT_NAME"; fi
	if test "$REQSCOPE" = "project"; then FN="$FN.$PRJ"; fi
	echo "$HOME/tmp/.otc.cache.$FN"
}

# Filename
readIAMTokenFile()
{
	local TKFN=$1
	if ! test -r $TKFN; then return 1; fi
	if test -n "$DISCARDCACHE" -o -n "$NOCACHE"; then return 1; fi
	local RESP=$(cat $TKFN)
	# TODO: Check for expiration in next minutes
	local now=$(date +"%s")
	# NOTE: This needs testing for keystonev2
	local exp=$(echo "$RESP" | tail -n1 | jq '.token.expires_at' | tr -d '"')
	if test "$exp" == "null" -o -z "$exp"; then exp=$(echo "$RESP" | tail -n1 | jq '.access.token.expires' | tr -d '"'); fi
	if test "$exp" == "null"; then return 1; fi
	exp=$(date -d "${exp%Z}" +"%s")
	if test -n "$DEBUG"; then echo "Token valid for $(($exp-$now))s" 1>&2; fi
	TOKEN=`echo "$RESP" | grep "X-Subject-Token:" | cut -d' ' -f 2`
	if test -z "$TOKEN"; then TOKEN=`echo "$IAMJSON" | jq -r '.access.token.id' | tr -d '"'`; fi
	if test $(($exp-$now)) -lt 900; then
		if test $(($exp-$now)) -ge 1; then echo "$TOKEN"; return 42; else return 2; fi
	fi
	# TODO: Check Token validity with HEAD /v3/auth/tokens
	if test -n "$CHECKTOKEN"; then
		curlheadauthparm $TOKEN "$IAM_AUTH_URL" -H "X-Subject-Token: $TOKEN" || return 3
	fi
	echo "$RESP"
}

# Filename, Header and Body
writeIAMTokenFile()
{
	local TKFN=$1
	if ! test -d "$(dirname $TKFN)"; then mkdir "$(dirname $TKFN)"; fi
	OLDUMASK=$(umask)
	umask 0177
	echo "$2" > $TKFN
	umask $OLDUMASK
}

getIAMTokenKeystone()
{
	local TENANT PROJECT USER SCOPE IAM_REQ RESP

	# Project by ID or by Name
	if test -n "$OS_PROJECT_ID"; then
		TENANT="\"tenantId\": \"$OS_PROJECT_ID\""
		PROJECT="\"project\": { \"id\": \"$OS_PROJECT_ID\" }"
	else
		TENANT="\"tenantName\": \"$OS_PROJECT_NAME\""
		PROJECT="\"project\": { \"name\": \"$OS_PROJECT_NAME\" }"
	fi
	# USER by ID or by Name
	if test -n "$OS_USER_ID"; then
		USER="\"id\": \"$OS_USER_ID\""
	else
		USER="\"name\": \"$OS_USERNAME\""
	fi
	# Token scope: project vs domain
	if test "$REQSCOPE" == "domain"; then
		SCOPE="\"scope\": { \"domain\": { \"name\": \"$OS_USER_DOMAIN_NAME\" } }"
	elif test "$REQSCOPE" == "unscoped"; then
		SCOPE=""
	else
		SCOPE="\"scope\": { $PROJECT }"
	fi

	if [[ "$IAM_AUTH_URL" = *"v3/auth/tokens" ]]; then
		if test -n "$OLDTOKEN" -a -n "$TOKENFROMTOKEN"; then
			IAM_REQ='{
				"auth": {
					"identity": {
					"methods": [ "token" ],
					"token": { "id": "'"$OLDTOKEN"'" }
				},
				'$SCOPE'
				}
			}'
		else
			IAM_REQ='{
				"auth": {
					"identity": {
						"methods": [ "password" ],
						"password": {
						"user": {
							'$USER',
							"password": "'"$OS_PASSWORD"'",
							"domain": { "name": "'"${OS_USER_DOMAIN_NAME}"'" }
						}
					}
					},
					'$SCOPE'
				}
			}'
		fi
		if test -n "$OS_PROJECT_DOMAIN_NAME"; then
			IAM_REQ=$(echo "$IAM_REQ" | sed "/\"project\":/i\ \t\t\t\t\"domain\": { \"name\": \"$OS_PROJECT_DOMAIN_NAME\" },")
		fi
	else
		IAM_REQ='{
			"auth": {
				'$TENANT',
				"passwordCredentials": {
					"username": "'"$OS_USERNAME"'",
					"password": "'"$OS_PASSWORD"'"
				}
			}
		}
		'
	fi
	export INAUTH=1
	RESP=$(curlpost "$IAM_REQ" "$IAM_AUTH_URL")
	RC=$?
	if test $RC != 0; then echo -e "ERROR: Authentication call failed\n$IAMRESP" 1>&2; exit $RC; fi
	unset INAUTH
	echo "$RESP"
}


# Get a token (and the project ID)
TROVE_OVERRIDE=0
IS_OTC=1
getIAMToken()
{
	if test -z "$OS_USERNAME" -o -z "$OS_PASSWORD" -o -z "$IAM_AUTH_URL"; then
		echo "ERROR: Need to set OS_USERNAME, OS_PASSWORD, OS_AUTH_URL, and OS_PROJECT_NAME environment" 1>&2
		echo " Optionally: OS_CACERT, HTTPS_PROXY, S3_ACCESS_KEY_ID, and S3_SECRET_ACCESS_KEY" 1>&2
		exit 1
	fi

	if test -z "$OS_PROJECT_ID"; then PRJ_ID_UNSET=1; fi

   REQSCOPE=${1:-project}
	local IAMRESP TKNFN=$(IAMTokenFilename)
	export BASEURL="${IAM_AUTH_URL/:443\///}" # remove :443 port when present
	BASEURL=${BASEURL%%/v[23]*}

	IAMRESP=$(readIAMTokenFile $TKNFN)
	RC=$?
	if test $RC != 0; then
		if test -n "$DEBUG"; then echo "No valid cached token, request from keystone" 1>&2; fi
		if test $RC = 42; then OLDTOKEN="$IAMRESP"; fi
		IAMRESP="$(getIAMTokenKeystone)"
		RC=$?
		if test $RC != 0; then exit $RC; fi
		if test -z "$NOCACHE"; then writeIAMTokenFile $TKNFN "$IAMRESP"; fi
	fi

	if [[ "$IAM_AUTH_URL" = *"v3/auth/tokens" ]]; then
		TOKEN=`echo "$IAMRESP" | grep "X-Subject-Token:" | cut -d' ' -f 2`
		#echo ${TOKEN} | sed -e 's/[0-9]/./g' -e 's/[a-z]/x/g' -e 's/[A-Z]/X/g'
		if test -z "$OS_PROJECT_ID"; then
			OS_PROJECT_ID=`echo "$IAMRESP" | tail -n1 | jq -r '.token.project.id'`
		fi

		if test -z "$TOKEN" -o -z "$OS_PROJECT_ID"; then
			echo "ERROR: Failed to authenticate and get token from $IAM_AUTH_URL for user $OS_USERNAME" 1>&2
			exit 2
		fi
		if test -z "$OS_USER_DOMAIN_ID"; then
			OS_USER_DOMAIN_ID=`echo "$IAMRESP" | getUserDomainIdFromIamResponse `
		fi
		if test -z "$OS_USER_DOMAIN_ID"; then
			echo "ERROR: Failed to determine user domain id from $IAM_AUTH_URL for user $OS_USERNAME" 1>&2
			exit 2
		fi
		# Parse IAM RESP catalogue
		local CATJSON=$(echo "$IAMRESP" | tail -n1 | jq '.token.catalog[]')
		local ROLEJSON=$(echo "$IAMRESP" | tail -n1 | jq '.token.roles[]')
		if test -n "$CATJSON" -a "$CATJSON" != "null"; then
			CINDER_URL=$(getcatendpoint "$CATJSON" volumev2 $OS_PROJECT_ID)
			NEUTRON_URL=$(getcatendpoint "$CATJSON" network $OS_PROJECT_ID)
			GLANCE_URL=$(getcatendpoint "$CATJSON" image $OS_PROJECT_ID)
			DESIGNATE_URL=$(getcatendpoint "$CATJSON" dns $OS_PROJECT_ID)
			NOVA_URL=$(getcatendpoint "$CATJSON" compute $OS_PROJECT_ID)
			HEAT_URL=$(getcatendpoint "$CATJSON" orchestration $OS_PROJECT_ID)
			TROVE_URL=$(getcatendpoint "$CATJSON" database $OS_PROJECT_ID)
			KEYSTONE_URL=$(getcatendpoint "$CATJSON" identity $OS_PROJECT_ID)
			CEILOMETER_URL=$(getcatendpoint "$CATJSON" metering $OS_PROJECT_ID)
			IRONIC_URL=$(getcatendpoint "$CATJSON" baremetal $OS_PROJECT_ID)
			MANILA_URL=$(getcatendpoint "$CATJSON" sharev2 $OS_PROJECT_ID)
			KARBOR_URL=$(getcatendpoint "$CATJSON" data-protect $OS_PROJECT_ID)
			#if test -n "$OUTPUT_CAT"; then echo "$CATJSON" | jq '.'; fi
			if test -n "$OUTPUT_CAT"; then echo "$CATJSON" | jq '.id+"   "+.type+"   "+.name+"   "+.endpoints[].url+"   "+.endpoints[].region+"   "+.endpoints[].interface' | tr -d '"' | sort -k2 -u; fi
			#if test -n "$OUTPUT_CAT"; then echo "$CATJSON" | jq 'def str(s): s|tostring; .id+"   "+.type+"   "+.name+"   "+str(.endpoints[])' | sed 's/\\"url\\"://' | tr -d '"'; fi
			if test -n "$OUTPUT_ROLES"; then echo "$ROLEJSON" | jq '.id+"   "+.name' | tr -d '"'; fi
			if test -n "$DEL_TOKEN"; then curldeleteauth $TOKEN "$IAM_AUTH_URL"; fi
		else
			SERVICES="$(curlgetauth $TOKEN ${IAM_AUTH_URL%auth*}services)"
			ENDPOINTS="$(curlgetauth $TOKEN ${IAM_AUTH_URL%auth*}endpoints)"
			#if test "$?" != "0"; then
			#	echo "ERROR: No keystone v3 service catalog" 1>&2
			#	exit 2
			#fi
			CINDER_URL=$(getendpoint "$SERVICES" "$ENDPOINTS" volumev2 $OS_PROJECT_ID)
			NEUTRON_URL=$(getendpoint "$SERVICES" "$ENDPOINTS" network $OS_PROJECT_ID)
			GLANCE_URL=$(getendpoint "$SERVICES" "$ENDPOINTS" image $OS_PROJECT_ID)
			DESIGNATE_URL=$(getendpoint "$SERVICES" "$ENDPOINTS" dns $OS_PROJECT_ID)
			NOVA_URL=$(getendpoint "$SERVICES" "$ENDPOINTS" compute $OS_PROJECT_ID)
			HEAT_URL=$(getendpoint "$SERVICES" "$ENDPOINTS" orchestration $OS_PROJECT_ID)
			TROVE_URL=$(getendpoint "$SERVICES" "$ENDPOINTS" database $OS_PROJECT_ID)
			KEYSTONE_URL=$(getendpoint "$SERVICES" "$ENDPOINTS" identity $OS_PROJECT_ID)
			CEILOMETER_URL=$(getendpoint "$SERVICES" "$ENDPOINTS" metering $OS_PROJECT_ID)
			IRONIC_URL=$(getendpoint "$SERVICES" "$ENDPOINTS" baremetal $OS_PROJECT_ID)
			MANILA_URL=$(getendpoint "$SERVICES" "$ENDPOINTS" sharev2 $OS_PROJECT_ID)
			KARBOR_URL=$(getendpoint "$SERVICES" "$ENDPOINTS" data-protect $OS_PROJECT_ID)
		fi
		if test -n "$OUTPUT_DOM"; then echo "$IAMRESP" | tail -n1 | jq '.token.project.domain.id' | tr -d '"'; fi
	else
		IS_OTC=0
		local IAMJSON=`echo "$IAMRESP" | tail -n1`
		TOKEN=`echo "$IAMJSON" | jq -r '.access.token.id' | tr -d '"'`
		if test -z "$OS_PROJECT_ID"; then
			OS_PROJECT_ID=`echo "$IAMJSON" | tail -n1 | jq -r '.access.token.tenant.id'`
		fi
		if test -z "$TOKEN" -o -z "$OS_PROJECT_ID"; then
			echo "ERROR: Failed to authenticate and get token from $IAM_AUTH_URL for user $OS_USERNAME" 1>&2
			exit 2
		fi
		local CATJSON=$(echo "$IAMRESP" | tail -n1 | jq '.access.serviceCatalog[]')
		local ROLEJSON=$(echo "$IAMRESP" | tail -n1 | jq '.access')
		CINDER_URL=$(getv2endpoint "$IAMJSON" volumev2 $OS_PROJECT_ID)
		NEUTRON_URL=$(getv2endpoint "$IAMJSON" network $OS_PROJECT_ID)
		GLANCE_URL=$(getv2endpoint "$IAMJSON" image $OS_PROJECT_ID)
		DESIGNATE_URL=$(getv2endpoint "$IAMJSON" dns $OS_PROJECT_ID)
		NOVA_URL=$(getv2endpoint "$IAMJSON" compute $OS_PROJECT_ID)
		HEAT_URL=$(getv2endpoint "$IAMJSON" orchestration $OS_PROJECT_ID)
		TROVE_URL=$(getv2endpoint "$IAMJSON" database $OS_PROJECT_ID)
		KEYSTONE_URL=$(getv2endpoint "$IAMJSON" identity $OS_PROJECT_ID)
		CEILOMETER_URL=$(getv2endpoint "$IAMJSON" metering $OS_PROJECT_ID)
		IRONIC_URL=$(getv2endpoint "$IAMJSON" baremetal $OS_PROJECT_ID)
		MANILA_URL=$(getv2endpoint "$IAMJSON" sharev2 $OS_PROJECT_ID)
		KARBOR_URL=$(getv2endpoint "$IAMJSON" data-protect $OS_PROJECT_ID)
		if test -n "$OUTPUT_CAT"; then echo "$CATJSON" | jq '.endpoints[].id+"   "+.type+"   "+.name+"   "+.endpoints[].publicURL+"   "+.endpoints[].region+"   public"' | tr -d '"' | sort -k2 -u; fi
		if test -n "$OUTPUT_ROLES"; then echo "$ROLEJSON" | jq '.metadata.roles[]+"   "+.user.roles[].name' | tr -d '"'; fi
	fi
	# FIXME: Delete this
	# For now fall back to hardcoded URLs
	if test -z "$NOVA_URL" -a "$IS_OTC" = "1" -a "$REQSCOPE" == "project"; then
		echo "WARN: Using hardcoded endpoints, will be removed" 1>&2
		CINDER_URL=${BASEURL/iam/evs}/v2/$OS_PROJECT_ID
		NEUTRON_URL=${BASEURL/iam/vpc}
		GLANCE_URL=${BASEURL/iam/ims}
		DESIGNATE_URL=${BASEURL/iam/dns}
		NOVA_URL=${BASEURL/iam/ecs}/v2/$OS_PROJECT_ID
		HEAT_URL=${BASEURL/iam/rts}/v1/$OS_PROJECT_ID
		TROVE_URL=${BASEURL/iam/rds}/v1.0
		IRONIC_URL=${BASEURL/iam/bms}
		MANILA_URL=${BASEURL/iam/sfs}/v2/$OS_PROJECT_ID
		KARBOR_URL=${BASEURL/iam/csbs}/v1/$OS_PROJECT_ID
	fi

	# DEBUG only: echo "$IAMRESP" | tail -n1 | jq -C .

	#if test -n "$DEBUG"; then
	#	echo "$IAMRESP" | sed 's/X-Subject-Token: MII.*$/X-Subject-Token: MIIsecretsecret/' 1>&2
	#fi
	if test -z "$KEYSTONE_URL"; then KEYSTONE_URL=$BASEURL/v3; fi
	if test -z "$CEILOMETER_URL"; then CEILOMETER_URL=${BASEURL/iam/ces}; fi

	AUTH_URL_ECS="$NOVA_URL/servers"
	export AUTH_URL_ECS_JOB="${NOVA_URL/v2/v1}/jobs"
	export AUTH_URL_ECS_DETAIL="$NOVA_URL/servers/detail"

	AUTH_URL_ECS_CLOUD="${NOVA_URL/v2/v1}/cloudservers"
	AUTH_URL_ECS_CLOUD_ACTION="$AUTH_URL_ECS_CLOUD/action"
	AUTH_URL_ECS_CLOUD_DELETE="$AUTH_URL_ECS_CLOUD/delete"
	AUTH_URL_FLAVORS="$AUTH_URL_ECS_CLOUD/flavors"
	AUTH_URL_KEYNAMES="$NOVA_URL/os-keypairs"

	AUTH_URL_VPCS="$NEUTRON_URL/v1/$OS_PROJECT_ID/vpcs"
	AUTH_URL_ROUTER="$NEUTRON_URL/v2.0/routers"
	AUTH_URL_PUBLICIPS="$NEUTRON_URL/v1/$OS_PROJECT_ID/publicips"
	AUTH_URL_SEC_GROUPS="$NEUTRON_URL/v1/$OS_PROJECT_ID/security-groups"
	#AUTH_URL_SEC_GROUP_RULES="$NEUTRON_URL/v2/$OS_PROJECT_ID/security-group-rules"
	AUTH_URL_SEC_GROUP_RULES="$NEUTRON_URL/v2.0/security-group-rules"
	AUTH_URL_SUBNETS="$NEUTRON_URL/v1/$OS_PROJECT_ID/subnets"

	AUTH_URL_IMAGES="$GLANCE_URL/v2/images"
	AUTH_URL_IMAGESV1="$GLANCE_URL/v1/cloudimages"
	AUTH_URL_IMAGESV2="$GLANCE_URL/v2/cloudimages"

	VBS_URL="${CINDER_URL/evs/vbs}"
	AUTH_URL_CVOLUMES="$CINDER_URL/cloudvolumes"
	AUTH_URL_CVOLUMES_DETAILS="$CINDER_URL/cloudvolumes/detail"
	AUTH_URL_VOLS="$CINDER_URL/volumes"
	AUTH_URL_CBACKUPS="$VBS_URL/cloudbackups"
	AUTH_URL_CBACKUPPOLS="$VBS_URL/backuppolicy"
	AUTH_URL_BACKS="$CINDER_URL/backups"
	AUTH_URL_SNAPS="$CINDER_URL/snapshots"

	AUTH_URL_ELB="${NEUTRON_URL/vpc/elb}/v1.0/$OS_PROJECT_ID/elbaas"
	AUTH_URL_ELB_LB="$AUTH_URL_ELB/loadbalancers"

	if test -z "$TROVE_URL"; then TROVE_URL=${BASEURL/iam/rds}; TROVE_OVERRIDE=1; fi
	AUTH_URL_RDS="${TROVE_URL%/v1.0}/rds"
	AUTH_URL_RDS_DOMAIN="${AUTH_URL_RDS}/v1/$OS_USER_DOMAIN_ID"
	AUTH_URL_RDS_PROJECT="${AUTH_URL_RDS}/v1/$OS_PROJECT_ID"

	AUTH_URL_DNS="$DESIGNATE_URL/v2/zones"

	# FIXME: Use full URLs that point to the service
	AUTH_URL_AS="${HEAT_URL/rts/as}"
	AUTH_URL_AS="${AUTH_URL_AS%%/v[12]*}/autoscaling-api/v1/$OS_PROJECT_ID"

	AUTH_URL_CES="$CEILOMETER_URL"
	AUTH_URL_CCE="${BASEURL/iam/cce}"

	AUTH_URL_KMS="${BASEURL/iam/kms}"
	AUTH_URL_SMN="${BASEURL/iam/smn}"
	AUTH_URL_CTS="${BASEURL/iam/cts}"
	AUTH_URL_DMS="${BASEURL/iam/dms}"
	AUTH_URL_MRS="${BASEURL/iam/mrs}"
	AUTH_URL_DEH="${BASEURL/iam/deh}"
	AUTH_URL_ANTIDDOS="${BASEURL/iam/antiddos}"
	AUTH_URL_DCS="${BASEURL/iam/dcs}/v1.0/$OS_PROJECT_ID"		# instances
	if test -n "$MANILA_URL"; then
		AUTH_URL_SFS="$MANILA_URL"
	else
		AUTH_URL_SFS="${BASEURL/iam/sfs}/v2/$OS_PROJECT_ID"	# shares
	fi
	# Catalog bug!
	if echo "$KARBOR_URL" | grep ' ' >/dev/null; then
		echo "WARN: Wrong CSBS URL: $KARBOR_URL, fixing up ..." 1>&2
		KARBOR_URL="${KARBOR_URL/ /}"
	fi
	#AUTH_URL_CSBS="${BASEURL/iam/csbs}/v1/$OS_PROJECT_ID"
	if test -n "$KARBOR_URL"; then AUTH_URL_CSBS="$KARBOR_URL"; else AUTH_URL_CSBS=${BASE_URL/iam/csbs}/v1/$OS_PROJECT_ID; fi
	AUTH_URL_DWS="${BASEURL/iam/dws}/v1.0/$OS_PROJECT_ID"
	AUTH_URL_TMS="${BASEURL/iam/tms}/v1.0"
	AUTH_URL_MAAS="${BASEURL/iam/maas}/v1/$OS_PROJECT_ID"
	AUTH_URL_NAT="${NEUTRON_URL/vpc/nat}/v2.0"
	AUTH_URL_DIS="${AUTH_URL_MRS/mrs/dis}/v2/$OS_PROJECT_ID"
	AUTH_URL_DCAAS="${NEUTRON_URL/vpc/dcaas}/v2.0/dcaas"
	AUTH_URL_MKT="${BASEURL/iam/marketplace}/v1"

	AUTH_URL_WORKSPACES="$BASEURL/v1.0/$OS_PROJECT_ID/workspaces"
	AUTH_URL_WORKSPACE_JOBS="$BASEURL/v1.0/$OS_PROJECT_ID/workspace-jobs"
	AUTH_URL_WORKSPACE_PRODUCTS="$BASEURL/v1.0/$OS_PROJECT_ID/products"
	AUTH_URL_WORKSPACE_DESKTOPS="$BASEURL/v1.0/$OS_PROJECT_ID/desktops"
}

build_data_volumes_json()
{
	local info_str=$1

	local DATA_VOLUMES=""
	disks=(${info_str//,/ })
	for disk in "${disks[@]}"; do
		info=(${disk//:/ })
		if test -n "$DATA_VOLUMES"; then
			DATA_VOLUMES="$DATA_VOLUMES, "
		fi
		DATA_VOLUMES="$DATA_VOLUMES{ \"volumetype\": \"${info[0]}\", \"size\": ${info[1]} }"
   done
	echo $DATA_VOLUMES
}

isnum()
{
	echo "$@" | grep '^[0-9]\{1,99\}$' >/dev/null 2>&1
}

jsonesc()
{
	if isnum "$@"; then
		echo "$@"
	elif test "$@" == "null" -o "$@" == "true" -o "$@" == "false"; then
		echo "$@"
	else
		echo "\"$@\""
	fi
}


keyval2list()
{
	local LIST=""
	OLDIFS="$IFS"
	IFS=","
	for tag in $*; do
		LIST="$LIST \"${tag/=/.}\","
	done
	IFS="$OLDIFS"
	echo "${LIST%,}"
}

keyval2listasterix()
{
	local LIST=""
	OLDIFS="$IFS"
	IFS=","
	for tag in $*; do
		LIST="$LIST \"${tag/=/*}\","
	done
	IFS="$OLDIFS"
	echo "${LIST%,}"
}

keyval2json()
{
	local JSON=""
	OLDIFS="$IFS"
	IFS=","
	for tag in $*; do
		KEY="${tag%%=*}"
		VAL="$(jsonesc ${tag#*=})"
		JSON="$JSON \"$KEY\": $VAL,"
	done
	IFS="$OLDIFS"
	echo "${JSON%,}"
}

keyval2keyvalue()
{
	local JSON=""
	OLDIFS="$IFS"
	IFS=","
	for tag in $*; do
		KEY="${tag%%=*}"
		if test "$KEY" != "$tag"; then
			VAL="$(jsonesc ${tag#*=})"
			JSON="$JSON { \"key\": \"$KEY\", \"value\": $VAL },"
		else
			JSON="$JSON { \"key\": \"$KEY\" },"
		fi
	done
	IFS="$OLDIFS"
	echo "${JSON%,}"
}

# Usage
ecsHelp()
{
	echo "--- Elastic Cloud Server (VM management) ---"
	echo "otc ecs list [FILTERS]     # list ecs instances (optional key=value filters)"
	echo "    --limit NNN            # limit records (works for most list functions)"
	echo "    --marker ID            # start with record after marker (UUID) (dito)"
	echo "    --maxgetkb NN          # auto-paginate (limiting responses to NN KiB max, def 250)"
	echo "otc ecs list-detail [ECS]  # list ecs instances in full detail (JSON)"
	echo "otc ecs details [ECS]      # list ecs instances in some detail (table)"
	echo "otc ecs show <vmid>        # show instance <vmid>"
	echo "otc ecs show2 <vmid>       # show instance <vmid> (nova v2.26)"
	echo "otc ecs console-log <vmid> # get console output from VM"
	echo "otc ecs create -n <name>   # create ecs instance <name>"
	echo
	echo "otc ecs create             # create vm example"
	echo "    --count 1              # one instance (default)"
	echo "    --public true          # with public ip"
	echo "    --file1 /tmp/A=/tmp/B  # inject local file /tmp/B to /tmp/A in VM"
	echo "    --file2 ...            # Up to 5 files can be injected this way"
	echo
	echo "otc ecs create             # create vm (addtl. options)"
	echo "    --instance-type       <FLAVOR>"
	echo "    --instance-name       <NAME>"
	echo "    --image-name          <IMAGE>"
	echo "    --boot-volume         <VOLUME>  # boot from volume instead of image [only create2]"
	echo "    --subnet-name         <SUBNET>"
	echo "    --fixed-ip            <IP>"
	echo "    --nicsubs <SUBN1>[:FIX1][,<SUBN2>[:FIX2][,...]]   # 2ndary NICs "
	echo "    --vpc-name            <VPC>"
	echo "    --security-group-name <SGNAME>"
	echo "    --security-group-ids  <SGID>,<SGID>,<SGID>"
	echo "    --admin-pass          <PASSWD>"
	echo "    --key-name            <SSHKEYNAME>"
	echo "    --user-data           <USERDYAMLSTRG> # don't forget #cloud-config header"
	echo "    --user-data-file      <USERDFILE>     # don't forget #cloud-config header"
	echo "    --public              <true/false/IP>"
	echo "    --volumes             <DEVICE:VOLUME>[,<DEVICE:VOLUME>[,..]]    # attach volumes as named devices"
	echo "    --bandwidth           <BW>		# defaults to 25"
	echo "    --bandwidth-name      <BW-NAME>	# defaults to bandwidth-BW"
	echo "    --disksize            <DISKGB>"
	echo "    --disktype            SATA|SAS|SSD	# SATA is default"
	echo "    --tenancy             <TENANCY> # use 'dedicated' for auto-placement on matching DedicatedHost"
	echo "    --dedicated-host      <HOST>    # use ID/Name of preexisting DedicatedHost for direct placement"
	echo "    --scheduler-hints JSON # pass raw JSON scheduler hints to nova (don't use with above two opts)"
	echo "    --datadisks           <DATADISK># format: <TYPE:SIZE>[,<TYPE:SIZE>[,...]]"
	echo "                                    #   example: SSD:20,SATA:50"
	echo "    --az                  <AZ>		# determined from subnet by default"
	echo "    --tags KEY=[VAL][,KEY=VAL[,...]]# add key-value pairs as tags"
	echo "    --inherit-tags                  # tag created rootdisk as well"
	echo "    --autorecovery true/false       # set autorecovery"
	echo "    --[no]wait"
	echo "otc ecs create2            # create vm with v2 API (same params, incomplete)"
	echo
	echo "otc ecs update <id>             # change VM data (same parms as create)"
	echo "    -r  specifies that tags or metadata will remove others"
	echo "otc ecs reboot-instances <id>   # reboot ecs instance <id>"
	echo "                                # optionally --soft/--hard/--wait"
	echo "otc ecs stop-instances <id>     # stop ecs instance <id>, dito"
	echo "                                # optionally --wait"
	echo "otc ecs start-instances <id>    # start ecs instance <id>"
	echo "                                # optionally --wait"
	echo "otc ecs delete                  # delete VM"
	echo "    --umount <dev:vol>[,..]     # umount named volumes before deleting the vm" ##### current issue
	echo "    --rename                    # prepend DEL_ to ECS names prior to queuing for deletion"
	echo "    --[no]wait                  # wait for completion (default: no)"
	echo "    --keepEIP                   # default: delete EIP too"
	echo "    --delVolume                 # default: delete only system volume, not any volume attached"
	echo "    <ecs> <ecs> ...             # specify IDs or names"
	echo "otc ecs job <id>                # show status of job <id>"
	echo "otc ecs limits                  # display project quotas"
	echo "otc ecs az-list                 # list availability zones"
	echo "otc ecs flavor-list             # list available flavors"
	echo "otc ecs (flp|flavor-pretty)     # tersely lists available flavors (aligned, min one-space to separate)"
	echo "otc ecs flp --spec [pattern]    # as above, but lists os_extra_spec, optionally grep-filtered for [pattern]"
	echo "                                # [pattern] must be escaped, eg: 'quota\|resource_type' including the ''"
	echo "otc ecs attach-nic ECSID PORT   # attach vNIC to VM: port-spec see below"
	echo "     --port-id PORTID           # Specify port-id"
	echo "     --net-id NETID [--fixed-ip IP]  # Specify net [and fixed-ip]"
	echo "otc ecs detach-nic ECSID PORT   # detach vNIC from VM"
}

taskHelp()
{
	echo "--- Task/Job management ---"
	echo "otc task show <id>              # show status of job <id> (same as ecs job)"
	echo "otc task delete <id>            # cancel job <id> (not yet supported)"
	echo "otc task wait <id> [sec]        # wait for job <id>, poll every sec sec (def: 2)"
}

keypairHelp()
{
	echo "--- SSH Keys ---"
	echo "otc keypair list                # list ssh key pairs"
	echo "otc keypair show <KPNAME>       # show ssh key pair"
	echo "otc keypair create <NAME> [<PUBKEY>]      # create ssh key pair"
	echo "otc keypair delete <KPNAME>     # delete ssh key pair"
}

evsHelp()
{
	echo "--- Elastic Volume Service (EVS) ---"
	echo "otc evs list [FILTERS]          # list all volumes (only id and name)"
	echo "otc evs details [FILTERS]       # detailed list all volumes (opt. key=value filters)"
	echo "otc evs show <id>               # show details of volume <id>"
	echo "otc evs tags <id>               # show tags of volume <id>"
	echo "otc evs describe <id>           # old iface for vol details, includes tags"
	echo "otc evs create                  # create a volume"
	echo "    --volume-name         <NAME>"
	echo "    --disksize            <DISKGB>"
	echo "    --disktype            SATA|SAS|SSD	# SATA is default"
	echo "    --az                  <AZ>"
	echo "    --multiattach               # create shareable volume"
	echo "    --crypt CRYPTKEYID          # encryption"
	echo "    --scsi/--vbd                # SCSI passthrough or plain VBD attachment"
	echo "    --tags KEY=[VAL][,KEY=VAL[,...]]      # add key-value pairs as tags"
	echo "otc evs update                  # change volume setting (name, descr, type, ...)"
	echo "otc evs delete                  # delete volume"
	echo
	echo "otc evs attach        ecsid    device:volumeid    # attach volume at ecs using given device name"
	echo "otc evs attach --name ecsname  device:volume      # use names instead of ids"
	echo "otc evs detach        ecsid   [device:]volumeid   # detach volume-id from ecs"
	echo "otc evs detach --name ecsname [device:]volume     # use names instead of ids"
	#TODO volume change ...
}

backupHelp()
{
	echo "--- Elastic Volume Backups ---"
	echo "otc backup list [FILTERS]              # List all backups (opt. key=value filters)"
	echo "otc backup show BACKUP"
	echo "otc backup create --name NAME VOL      # Create backup from volume"
	echo "otc backup restore BACKUP VOL          # restore backup to volume"
	echo "otc backup delete BACKUP"
	echo "otc snapshot list [FILTERS]            # list snapshots"
	echo "otc snapshot show SNAP                 # details of snapshot snapid"
	echo "otc snapshot delete SNAP               # delete snapshot snapid"
	echo "otc backuppolicy list                  # list backup policies"
	echo "otc backuppolicy show NAME|ID          # details of backup policy"
	echo "otc backuppolicy create [options] NAME # create backup policy"
	echo "    --time HH:mm                       # option: UTC time to start backup"
	echo "    --freq N                           # no of days b/w backups"
	echo "    --retain N                         # no of backups to retain (min 2)"
	echo "    --retain1st Y/N                    # retain first backup of curr month"
	echo "    --enable/disable                   # enable/disable (def: enable)"
	echo "    --tags key=val,...                 # key-value pairs as tags (optional)"
	echo "otc backuppolicy update NAME|ID        # update backup policy (same params as above)"
	echo "otc backuppolicy delete ID             # delete backup policy (by NAME or ID)"
	echo "otc backuppolicy add ID VOLID [VOLID [...]]       # add volumes to policy (dito)"
	echo "otc backuppolicy remove ID VOLID [VOLID [...]]    # remove vols from policy (...)"
	echo "otc backuppolicy execute ID            # trigger backup policy to run once (...)"
	echo "otc backuppolicy showtasks ID          # show jobs triggered by policy (JSON)"
	echo "otc backuppolicy listtasks ID          # show jobs triggered by policy (list)"
}

vpcHelp()
{
	echo "--- Virtual Private Network (VPC) Router ---"
	echo "otc vpc list                    # list all vpc"
	echo "otc vpc show VPC                # display VPC (Router) details"
	echo "otc vpc delete VPC              # delete VPC"
	echo "otc vpc create                  # create vpc"
	echo "    --vpc-name <vpcname>"
	echo "    --cidr     <cidr>"
	echo "    --tags KEY=[VAL][,KEY=VAL[,...]]      # add key-value pairs as tags"
	echo "otc vpc listroutes VPC          # list VPC routes"
	echo "otc vpc addroute VPC DEST NHOP  # add a route to VPC router with dest and nexthop"
	echo "otc vpc delroute VPC DEST [NHOP]# delete VPC route"
	echo "otc vpc en/disable-snat VPC     # enable/disable snat"
	echo "otc vpc limits                  # list VPC related quota"
	echo "--- VPC Peering ---"
	echo "otc vpcpeer list [FILTERS]      # List VPC peerings. Optional FILTERS are key=value pairs"
	echo "otc vpcpeer show NAME|ID        # Show details of VPC peering"
	echo "otc vpcpeer create VPCR VPCA    # Create peering req from VPCR to VPCA (IDs or names)"
	echo "    --name <peername>           # optional name (will get autogen otherwise)"
	echo "    --project-id <accproject>   # project (tenant) ID of VPCA, only required if not us"
	echo "otc vpcpeer accept ID|NAME      # accept peering request"
	echo "otc vpcpeer reject ID|NAME      # refuse peering request"
	echo "otc vpcpeer update ID|NAME      # update peering request"
	echo "    --name <peername>           # updated name"
	echo "otc vpcpeer ID|NAME             # Delete peering"
}

subnetHelp()
{
	echo "--- Subnets ---"
	echo "otc subnet list                 # list all subnet"
	echo "otc subnet show <SID>           # show details for subnet <SID>"
	echo "otc subnet delete <SID>         # delete subnet <SID>"
	echo "    --vpc-name          <vpcname>"
	echo "otc subnet create               # create a subnet"
	echo "    --subnet-name       <subnetname>"
	echo "    --cidr              <cidr>"
	echo "    --gateway-ip        <gateway>"
	echo "    --primary-dns       <primary-dns>"
	echo "    --secondary-dns     <sec-dns>"
	echo "    --availability-zone <avalibility zone>"
	echo "    --vpc-name          <vpcname>"
	echo "    --tags KEY[=VAL][,KEY=VAL[,...]]      # add key-value pairs as tags"
}

eipHelp()
{
	echo "--- Public IPs ---"
	echo "otc publicip list               # list all publicips"
	echo "otc publicip create             # create a publicip"
	echo "    --bandwidth-name    <bandwidthame>"
	echo "    --bandwidth         <bandwidth>"
	echo "    --address           <Public IP addr>"
	echo "    --pep                       # create a 198.19.16/20 address"
	echo "otc publicip update <id/ip>     # change name and/or bandwidth (same opts)"
	echo "otc publicip delete <id/ip>     # delete a publicip (EIP)"
	echo "otc publicip bind <id/ip> <port-id>       # bind a publicip to a port / private IP"
	echo "otc publicip unbind <id/ip>               # unbind a publicip"
	# TODO: bandwidth
	echo "otc publicip6 list              # list all IPv6 floating ips"
	echo "otc publicip6 ...               # same commands available as for IPv4 (except update)"
	echo "                                # currently not well tested (as not yet supported)"
	echo "                                # bandwidth control is not available either"
}

sgHelp()
{
	echo "--- Security Groups ---"
	echo "otc security-group list                   # list all sec. group"
	echo "otc security-group-rules list <group-id>  # list rules of sec. group <group-id>"
	echo "otc security-group create                 # create security group"
	echo "    -g <groupname>"
	echo "    --vpc-name <vpc name>"
	echo "    --description <desc>			# optional description"
	echo "otc security-group delete SGID            # delete security group"
	echo "otc security-group-rules create           # create sec. group rule"
	echo "    --security-group-name <secgroupname>"
	echo "    --direction           <direction>"
	echo "    --protocol            <protocol: tcp, udp, icmp>"
	echo "    --ethertype           <ethtype: IPv4,IPv6>"
	echo "    --portmin             <port range lower end>"
	echo "    --portmax             <port range upper end>"
	echo "    --remotegroup         <ID/name of remote security group>"
	echo "    --remoteip            <CIDR of remote IP>"
	echo "    --description         <desc>          # optional description"
}

imageHelp()
{
	echo "--- Image Management Service (IMS) ---"
	echo "otc images list [FILTERS]       # list all images (optionally use prop filters)"
	echo "otc images show <img>           # show image details"
	echo "otc images upload <img> filename          # upload image file (OTC-1.1+)"
	echo "otc images upload <img> bucket:objname    # specify image upload src (via s3)"
	echo "otc images download <img> bucket:objname  # export priv image into s3 object"
	echo "otc images create NAME          # create (private) image with name"
	echo "    --disk-format  <disk-format>"
	echo "    --min-disk     <GB>"
	echo "    --min-ram      <MB>         # optional (default 1024)"
	echo "    --os-version   <os_version> # optional (default Other)"
	echo "    --property     <key=val>    # optional properties (multiple times possible)"
	echo "    --type <type> --description <desc> # optional settings (see below)"
	echo "otc images create NAME          # create image from ECS instance (snapshot)"
	echo "    --image-name   <image name>"
	echo "    --instance-id  <instance id>"
	echo "    --description  <description># optional description"
	echo "    --type <type>               # optional: FusionCompute (ECS, default) or Ironic (BMS)"
	echo "otc images copy SRCIMAGE NEWIMAGENAME     # copy an IMS image within a region"
	echo "    --description  <description>          # optional"
	echo "    --cmk_id  <encryption key id>         # optional"
	echo "otc images register NAME FILE   # create (private) image with name and s3 file"
	echo "    --property, --min-disk, --os-version and --wait supported"
	echo "otc images update <img>         # change properties, --image-name, --min-*"
	echo "otc images delete <img>         # delete (private) image by ID/name"
	echo
	echo "otc images listshare <img>      # list projects image id is shared with"
	echo "otc images showshare <img> <prj># show detailed image sharing status"
	echo "otc images share <img> <prj>    # share image id with prj"
	echo "otc images unshare <img> <prj>  # stop sharing img id with prj"
	echo "otc images acceptshare <img> [<prj>]      # accept image id shared into prj (default to self)"
	echo "otc images rejectshare <img> [<prj>]      # reject image id shared into prj"
}

elbHelp()
{
	echo "--- Classic Elastic Load Balancer (ELBv1) ---"
	echo "otc elb list            # list all classic load balancers"
	echo "otc elb show <eid>      # show elb details (eid can also be name)"
	echo "otc elb create [<vpcid> [<name> [<bandwidth>]]]   # create new elb"
	echo "    --vpc-name <vpcname>"
	echo "    --bandwidth <bandwidth>               # in Mbps"
	echo "    --subnet-name/id <subnet>             # creates internal ELB listening on subnet"
	echo "    --security-group-name/id <secgroup>   # for internal ELBs"
	echo "otc elb delete <eid>            # Delete ELB with <eid>"

	echo "otc elb listlistener <eid>      # list listeners of load balancer <eid>"
	echo "otc elb showlistener <lid>      # show listener detail <lid>"
	echo "otc elb addlistener <eid> <name> <proto> <port> [<alg> [<beproto> [<beport>]]]"
	echo "    --timeout <min>             # timeout in minutes(!) for TCP/UDP"
	echo "    --cookieto <min>            # sticky session cookie timeout (min) (roundrobin HTTP/S)"
	echo "    --drain <min>               # keep conn after member del in minutes(!) for TCP"
	echo "    --sslcert <id>              # SSL cert to use for HTTPS, comma-sep list for SNI"
	echo "    --sslproto <TLS>            # TLSv1.2 or TLSv1.2 TLSv1.1 TLSv1 (only HTTPS)"
	echo "    --sslcipher <Kwd>           # Default or Strict or Extended (Ext for v1.2+1.1+1)"
	#not implemented: modifylistener
	echo "otc elb dellistener <lid>       # delete listener by ID/NAME"
	echo "otc elb listmember <lid>"
	echo "otc elb showmember <lid> <mid>  # show member details by name/IP"
	echo "otc elb addmember <lid> <vmid> <vmip>"
	echo "otc elb delmember <lid> <mid> <vmip>"
	#elb listcheck <lid> is missing (!) from API
	echo "otc elb showcheck <cid/lnm>     # show healtcheck by check ID / listener name"
	echo "otc elb addcheck <lid> <proto> <port> <int> <to> <hthres> <uthres> [<uri>]"
	echo "otc elb delcheck <cid>"
	#
	echo "otc elb listcert                # Show certs for SSL termination"
	echo "otc elb createcert [opt] CERT PRIV [NAME [DOM]]   # SSL certificate creation (PEM files)"
	echo "    --name NAME --description DESC --domain DOM   # domain needed for SNI"
	echo "otc elb updatecert ID/NM [NEWNM]# Update cert name/desc (same opts as above)"
	echo "otc elb showcert ID/NM          # SSL certificate details"
	echo "otc elb deletecert ID/NM        # SSL certificate deletion"

	echo "--- Unified Load Balancer (ULB aka LBaaSv2) ---"
	echo "otc ulb list            # list all unified load balancers/ELBv2"
	echo "otc ulb show <ulb>      # show details of <ulb>"
	echo "otc ulb details <ulb>   # show more details of <ulb>"
}

asHelp()
{
	echo "--- Autoscaling Help (AS) ---"
	echo "otc asgroup list [FILT] # list all autoscaling groups"
	echo "otc asgroup show AGRP   # show details of autoscaling group AGRP"
	echo "otc asgroup vms AGRP    # show instances of autoscaling group AGRP"
	echo "otc asgroup log AGRP    # get action log of autoscaling group AGRP"
	echo "otc asconfig list       # list all autoscaling configurations"
	echo "otc asconfig show ACFG  # show details of autscaling config ACFG"
	echo "otc aspolicy list AGRP  # list all autoscaling policies for AGRP"
	echo "otc aspolicy show APOL  # show details of autscaling config APOL"
	echo "otc as limits [AGRP]    # show quotas for autoscaling"
	echo "otc as tags TYPE [RID]  # list tags for AS TYPE"
}

rdsHelp()
{
	echo "--- Relational Database Service (RDS) ---"
	echo "otc rds list"
	echo "otc rds listinstances                                # list database instances"
	echo "otc rds show [<id> ...]"
	echo "otc rds showinstances  [<id> ...]                    # show database instances details"
	echo "otc rds apis"
	echo "otc rds listapis                                     # list API ids"
	echo "otc rds showapi <id> ...                             # show API detail information"
	echo "otc rds showdatastore MySQL|PostgreSQL ...           # show datastore ids and metadata"
	echo "otc rds datastore ...                                # alias for 'showdatastore'"
	echo "otc rds showdatastoreparameters <datastore_id> ...   # show all configuration parameters"
	echo "otc rds showdatastoreparameter <datastore_id> <name> # show a configuration parameter"
	echo "otc rds listflavors <datastore_id>"
	echo "otc rds flavors <datastore_id>                       # list RDS flavors"
	echo "otc rds showflavor <id> ...                          # RDS flavor details"
	echo "otc rds create [<configfile>]                        # create RDS instance, read from"
	echo "                                                     # stdin when no config file is given"
	echo "otc rds delete <id> <backups>                        # remove RDS instances and backups"
	echo "otc rds showbackuppolicy <id> ...                    # show backup policy of database <id>"
	echo "otc rds listsnapshots                                # list all backups"
	echo "otc rds listbackups                                  # alias for 'listsnapshots'"
	echo "otc rds showerrors <id> <startDate> <endDate>        # shows db instance errors currently"
	echo "                        <page> <entries>             # limited to last month and MySQL"
	echo "otc rds showslowstatements                           # shows db instance errors currently"
	echo "                        <id>                         # id of db instance"
	echo "                        select|insert|update|delete  # one of the statement type"
	echo "                        <entries>                    # top longest stmts to show (1-50)"
	echo "otc rds showslowqueries ...                          # alias for 'showslowstatements'"
	echo "otc rds createsnapshot <id> <name> <description>     # create a snapshot from an instance"
	echo "otc rds createbackup ...                             # alias for 'createsnapshot'"
	echo "otc rds deletesnapshot <id>                          # deletes a snapshot of an instance"
	echo "otc rds deletebackup ...                             # alias for 'deletesnapshot'"
}

dnsHelp()
{
	echo "--- DNS ---"
	echo "otc domain list         # show all zones/domains"
	echo "otc domain show zid     # show details of zone/domain <zid>"
	echo "otc domain delete zid   # deleted zone/domain <zid>"
	echo "otc domain create [options] domain [desc [type [mail [ttl]]]]"
	echo "                        # create zone for domain (name. or ...in-addr.arpa.)"
	echo "                        # desc, public/private, mail, ttl (def: 300s) optional"
	echo "otc domain addrecord	zid name. type ttl val [desc]"
	echo "                        # add record to zone <zid> for <name> with <type>, <ttl>"
	echo "                        # type could be A, AAAA, MX, CNAME, PTR, TXT, NS"
	echo "                        # val is a comma sep list of record values, e.g."
	echo "                        # IPADDR, NR NAME, NAME, NAME, STRING, NAME."
	echo "otc domain showrecord zid rid     # show record <rid> for zone <zid>"
	echo "otc domain listrecords [zid]      # list records for zone <zid>"
	echo "otc domain delrecord zid rid      # delete record <rid> in zone <zid>"
	echo "otc domain associate  zid vpc     # connect vpc to private DNS server zid"
	echo "otc domain dissociate zid vpc     # discconnect vpc from private DNS zid"
}

cceHelp()
{
	echo "--- Cloud Container Engine (CCE) ---"
	echo "otc cluster list                  # list container clusters (short)"
	echo "otc cluster list-detail           # list container clusters (detailed)"
	echo "otc cluster show <cid>            # show container cluster details of cid"
	echo "otc cluster delete <cid>          # delete container cluster cid"
	echo "otc cluster create [opts] <name>  # create new container cluster with name"
	echo "   --type Single/HA               # Single Master or HA master (mandatory)"
	echo "   --vpc-name <vpc> or --vpc-id <vpc>        # VPC (mandatory)"
	echo "   --subnet-name <sub> or --subnet-id <sub>  # SubNet (mandatory)"
	echo "   --az <az> --description <dec>  # AZ and description (optional)"
	echo "   --security-group-name <sg>     # Security Group (optional)"
	echo "otc host list <cid>               # list container hosts of cluster cid"
	echo "otc host show <cid> <hid>         # show host hid details (cluster cid)"
	echo "otc host create [opts] <cid> <nr> # deploy nr hosts in cluster cid"
	echo "   --disks TYPE:SIZE,TYPE:SIZE,...# disk config (mand), SATA/SAS/SSD:GB"
	echo "   --instance-type <flavor>       # VM flavors to deploy (mandtory)"
	echo "   --key-name <key>               # SSH key to inject (mand)"
	echo "   --name <label> --az <az>       # assign label and set AZ (both optional)"
	echo "   --snat --tags <tag,tag=v,..>   # optional snat and tags"
	echo "otc host delete <cid> <hid> [<hid> [...]] # remove hosts hid from cluster cid"
}

iamHelp()
{
	echo "--- Access Control (IAM) ---"
	echo "otc iam token           # generate a new iam token"
	echo "otc iam catalog         # catalog as returned with token"
	echo "otc iam domain          # output domain ID"
	echo "otc iam listdomains     # domain list"
	echo "otc iam project         # output project_id/tenant_id"
	echo "otc iam listprojects    # output project list"
	echo "otc iam showproject ID  # show details of project"
	echo "otc iam showextproject ID         # show details of project including status"
	echo "otc iam createproject NAME        # create project (opt: --description)"
	echo "otc iam deleteproject ID          # delete project (fails on OTC to avoid orphaned resrcs)"
	echo "otc iam cleanproject ID           # recursive project cleanup (grace period of some hours)"
	echo "otc iam recoverproject ID         # stop recursive project cleanup"
	echo "otc iam services        # service catalog"
	echo "otc iam endpoints       # endpoints of the services"
	echo " --- Roles and Role Assignments ---"
	echo "otc iam roles           # list project roles (add --domainscope for domain role)"
	echo "otc iam roles2          # show available role policies"
	echo "otc iam listroles       # list available role policies"
	echo "otc iam showrole RID    # output properties of role RID"
	echo "otc iam listrolegroup GRP         # list roles of group GRP"
	echo "    --project PRJID               # optionally list project instead of domain roles"
	echo "otc iam addrolegroup RID GRP      # assign role RID to group GRP (optional: --project PRJID)"
	echo "otc iam delrolegroup RID GRP      # remove role RID from group GRP (optional: --project PRJID)"
	echo "                        # corresponding list/add/delroleuser implementd by not supp on OTC"
	echo " --- Groups --- "
	echo "otc iam groups          # show groups"
	echo "otc iam listgroups      # get group list"
	echo "otc iam addgroup GRP    # create user with groupname GRP"
	echo "   --domainid ID        # set domain ID"
	echo "   --description DESC   # description of group"
	echo "   --name GRP           # change groupname"
	echo "otc iam changegroup GRP # change group properties (same params as addgroup)"
	echo "otc iam showgroup GRP   # details on USER (by ID or username)"
	echo "otc iam delgroup GRP    # delete USER (by ID or username)"
	echo "otc iam listusergroup GRP         # list members(users) of group"
	echo "otc iam checkgroup GRP USER       # test membership of USER in GRP"
	echo "otc iam addgroupuser GRP USER     # add USER to GRP"
	echo "otc iam delgroupuser GRP USER     # del USER from GRP"
	echo " --- Users ---"
	echo "otc iam users           # show users"
	echo "otc iam listusers       # get user list"
	echo "otc iam adduser USER    # create user with username USER"
	echo "   --password PWD       # password"
	echo "   --en/disabled        # disabled/enabled(default)"
	echo "   --default-project ID # set default project ID"
	echo "   --description DESC   # description of user"
	echo "   --name USER          # change username"
	echo "otc iam changeuser USER # change user properties (same params as adduser)"
	echo "otc iam showuser USER   # details on USER (by ID or username)"
	echo "otc iam deluser USER    # delete USER (by ID or username)"
	echo "--- Access Control: Federation ---"
	echo "otc iam listidp         # list Identity Providers"
	echo "otc iam showidp IDP     # details of IDP"
	echo "otc iam listmapping     # list mappings"
	echo "otc iam showmapping IDP # details of mapping IDP"
	echo "otc iam listprotocol    # list of federation protocols"
	echo "otc iam showprotocol PR # show details of federation protocal"
	echo "otc iam keystonemeta    # show keystone metadata"
}

cesHelp()
{
	echo "--- Monitoring & Alarms (Cloud Eye) ---"
	echo "otc metrics list [NS [MET [SELECTORS]]]  # display list of avail metrics"
	echo "otc metrics favorites                    # display list of favorite metrics"
	echo "otc metrics show NS MET FROM TO PER AGR [SELECTORS]	# get metrics"
	echo "      NS = namespace (e.g. SYS.ECS), MET = metric_name (e.g. cpu_util)"
	echo "      FROM and TO  are timestamps in s since 1970, use NOW-3600 for 1h ago"
	echo "      PER = 1, 300, 1200, 3600, 14400, 86400  period b/w data points in s"
	echo "      AGR = min, max, average, variance  to specify aggregation mode"
	echo "      SELECTORS  define which data is used with up to three key=value pairs"
	echo "        e.g. instance_id=00826ea4-aa15-4725-9fa7-8ea10f765a3f"
	echo "      Note that timestamps in response are in s since 1970 (UTC)"
	echo "      API docu calls SELECTORS dimensions and aggregation mode filter"
	echo "      Example: otc metrics list \"\" \"\" instance_id=\$VMUUID"
	echo "otc alarms list         # list configured alarms"
	echo "otc alarms limits       # display alarm quotas"
	echo "otc alarms show ALID    # display details of alarm ALID"
	echo "otc alarms delete ALID  # delete alarm ALID"
	echo "otc alarms en/disable ALID        # enable/disable ALID"
}

heatHelp()
{
	echo "--- HEAT (RTS) ---"
	echo "otc stack list          # List heat stacks"
	echo "otc stack show SID      # Show stack SID (Name or ID)"
	echo "otc stack resources SID # List stack resources"
	echo "otc stack showresource SID        # Show resource details"
	echo "otc stack events SID    # List stack events"
	echo "otc stack template SID  # Display stack template"
	echo "otc stack resourcetypes # Show supported resource types"
	echo "otc stack buildinfo     # Show build information"
	echo "otc stack deployments   # List deployed stacks"
	echo "otc stack showdeployment DID      # Show deployment details"
}

smnHelp()
{
	echo "--- OTC2.0 Simple Message Notification ---"
	echo "otc notifications list            # List notification topics"
	echo "otc notifications show URN        # Show details of topic URN"
	echo "otc notifications create TOP [DESC]       # New notification topic"
	echo "otc notifications delete URN      # Delete notification topic"
	echo "otc notifications subscriptions   # Show all notification subscriptions"
	echo "otc notifications subscribe URN PROTO ADDR [REM] # Subscribe to topic URN"
	echo "otc notifications unsubscribe SUB # Unsubscribe from topic URN"
	echo "otc notifications publish URN SUBJECT     # Publish notification (stdin)"
	echo "otc notifications SMS NUM TEXT    # Send SMS message"
}

#elif [ "$MAINCOM" == "queues" -a "$SUBCOM" == "getmsg" ]; then
#	getMessage "$@"
#elif [ "$MAINCOM" == "queues" -a "$SUBCOM" == "ackmsg" ]; then
#	ackMessage "$@"
dmsHelp()
{
	echo "--- OTC2.0 Distributed Messaging Service ---"
	echo "otc queues list         # List DMS queues"
	echo "otc queues show QID     # Show queue QID"
	echo "otc queues create NAME [DESC]     # Create queue with NAME (opt: DESCription)"
	echo "otc queues delete QID   # Delete queue QID"
	echo "otc queues limits       # Show queuing quota"
	echo "otc queues consumers QID          # Show consumer groups for queue QID"
	echo "otc queues createconsumer QID NM  # Create consumer group with name NM for queue QID"
	echo "otc queues deleteconsumer QID GID # Delete consumer group with ID GIM for queue QID"
	echo "otc queues queuemsg QID [K=V [..]]# Send message to queue QID (read JSON from stdin"
	echo "    --attributes JSON             # or pass key-value pairs). Attributes are optional"
	echo "    --attrkv K=V[,K=V[,..]]       # and can be passed as JSON or KEY=VALUE pairs"
	echo "otc queues getmsg QID GID         # Read message from queue QID for cons group GID (JSON)"
	echo "    --kv                          # Output as key[N]=value statements (be aware of sec!)"
	echo "    --maxmsg N                    # Return at most N messages"
	echo "    --ack                         # Acknowledge message receipt(s)"
	echo "otc queues ackmsg QID NM H1 [..]  # Acknowledge message receipt by handles H1 ..."
}

customHelp()
{
	echo "--- Custom command support ---"
	echo "otc custom [--jqfilter FILT] [--paginate ARRNAME] METHOD URL [JSON] # Send custom command"
	echo "      METHOD=GET/PUT/POST/DELETE/HEAD, vars with \\\$ are evaluated (not sanitized!)"
	echo "      example: otc custom GET \\\$BASEURL/v2/\\\$OS_PROJECT_ID/servers"
	echo "      note that \\\$BASEURL gets prepended if URL starts with /"
	echo "    --jqfilter allows to use a filtering string for jq processing (def=.)"
	echo "      e.g.: --jqfilter '.servers[] | .id+\\\"   \\\"+.name' GET \\\$NOVA_URL/servers"
}

tagHelp()
{
	echo "--- OTC2.x new services ---"
	echo "otc tags list           # List predefined tags"
	echo "otc tags create KEY=VAL [KEY2=VAL2 [...]] # Create tags"
	echo "otc tags delete KEY=VAL [KEY2=VAL2 [...]] # Delete tags"
}

otcnewHelp()
{
	echo "--- OTC2.x new services ---"
	echo "NOTE: These are not complete and some list output is JSON, not list format"
	echo "otc trace list          # List trackers from cloud trace"
	echo "otc trace show (IAM|ECS|CTS)      # List traces from cloud bucket"
	echo "otc antiddos list       # List AntiDDOS policies"
	echo "otc kms list            # List keys from key management service"
	echo "otc shares list         # List shared filesystems"
	echo "otc cache list          # List distributed cache instances"
	echo "otc dws list            # List data warehous clusters"
	echo "otc serverbackup list   # List server backup checkpoints"
	echo "otc migration list      # List migration tasks"
}

otcnew3Help()
{
	echo "--- OTC3.x new services ---"
	echo "NOTE: These are not complete and some list output is JSON, not list format"
	echo "otc natgw list          # List NAT gateways"
	echo "otc natgw rules         # List SNAT rules"
	echo "otc dcaas list          # List Direct Connections"
	echo "otc dcaas gateways      # List Virtual Gateways"
	echo "otc dcaas interfaces    # List Virtual Interfaces"
	echo "otc dcaas endpoints     # List Endpoint Groups"
	echo "otc dis list            # List Data Ingestion Streams"
	echo "otc product categories  # List products from marketplace"
}

dehHelp()
{
	echo "--- Dedicated Host (DEH) ---"
	echo "otc deh list            # List Dedicated Hosts"
	echo "otc deh show <id>       # Show Dedicated Host Details (specify ID or name)"
	echo "otc deh listvm <id>     # List VMs on Dedicated Host"
	echo "otc deh create NAME TYPE NUM      # Allocate Dedicated Hosts"
	echo "    --az AZ"
	echo "    --auto on/off       # allow VMs to be placed here automatically"
	echo "otc deh delete <id>     # Release Dedicated Host"
	echo "otc deh listtypes <az>  # List avail Dedicated Host types"
}

workspaceHelp()
{
	echo "--- Workspace ---"
	echo "otc workspace query           # query workspace details"
	echo "otc workspace apply           # apply for workspace"
	echo "    --az                      <az>"
	echo "    --vpc-name                <vpc>"
	echo "    --subnet-name             <subnet>"
	echo "    --domain-type             LITE_AD | LOCAL_AD"
	echo "    --domain-name             <FQDN>"
	echo "    --domain-admin-account    <username>"
	echo "    --domain-admin-password   <password>"
	echo "    --active-domain-ip        <IP>        # (LOCAL_AD only)"
	echo "    --active-dns-ip           <IP>        # (LOCAL_AD only)"
	echo "    --access-mode             INTERNET | DEDICATED | BOTH"
	echo "    --[no]wait"
	echo "otc workspace cancel          # cancel workspace"
}

workspaceJobHelp()
{
	echo "--- Workspace Job Management ---"
	echo "otc workspace-job show <id>         # show status of job <id>"
	echo "otc workspace-job wait <id> [sec]   # wait for job <id>, poll every sec seconds (default: 2)"
}

workspaceDesktopHelp()
{
	echo "--- Workspace Desktops ---"
	echo "otc workspace-desktop list          # query list of workspace desktops"
}

workspaceProductHelp()
{
	echo "--- Workspace Products ---"
	echo "otc workspace-product list          # query list of workspace products"
}

mdsHelp()
{
	echo "--- Metadata helper ---"
	echo "otc mds meta_data [FILT]          # Retrieve and output meta_data"
	echo "otc mds vendor_data [FILT]        # Retrieve and output vendor_data"
	echo "      FILT is an optional jq string to process the data"
	echo "otc mds user_data                 # Retrieve and output user_data"
	echo "otc mds password                  # Retrieve and output password (unused)"
}

printHelp()
{
	echo "otc-tools version $VERSION: OTC API tool"
	echo "Usage: otc.sh [global flags] service action [options] [params]"
	echo "--- Global flags ---"
	echo "otc --debug CMD1 CMD2 [opts] PARAMS       # for debugging REST calls ..."
	echo "otc --insecure CMD1 CMD2 [opts] PARAMS    # for ignoring SSL security ..."
	echo "    --domainscope       # get/use a domain scoped token"
	echo "    --projectscope      # get/use a project scoped token"
	echo "    --unscoped          # get/use an unscoped token"
	echo "    --discardcache      # don't use token from cache but request new one"
	echo "    --nocache           # ignore token cache"
	echo
	ecsHelp
	echo
	taskHelp
	echo
	keypairHelp
	echo
	evsHelp
	#echo
	backupHelp
	echo
	vpcHelp
	echo
	subnetHelp
	echo
	eipHelp
	echo
	sgHelp
	echo
	imageHelp
	echo
	elbHelp
	echo
	asHelp
	echo
	rdsHelp
	echo
	dnsHelp
	echo
	cceHelp
	echo
	iamHelp
	echo
	cesHelp
	echo
	heatHelp
	echo
	smnHelp
	echo
	dmsHelp
	echo
	tagHelp
	echo
	otcnewHelp
	echo
	otcnew3Help
	echo
	dehHelp
	echo
	workspaceHelp
	echo
	workspaceJobHelp
	echo
	workspaceDesktopHelp
	echo
	workspaceProductHelp
	echo
	customHelp
	echo
	mdsHelp
	echo
	echo "Use otc.sh service help to get help for one service only"
}


# Functions

# Check if $1 is in uuid format
is_uuid()
{
	echo "$1" | grep '^[0-9a-f]\{8\}\-[0-9a-f]\{4\}\-[0-9a-f]\{4\}\-[0-9a-f]\{4\}\-[0-9a-f]\{12\}$' >/dev/null 2>&1
}

is_id()
{
	echo "$1" | grep '^[0-9a-f]\{32\}$' >/dev/null 2>&1
}

is_ip4()
{
	echo "$1" | grep '^[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}$' >/dev/null 2>&1
}

is_ip6()
{
	echo "$1" | grep '^[0-9a-fA-F:]*\$' >/dev/null 2>&1
}

getid()
{
	head -n1 | cut -d':' -f2 | tr -d '" ,'
}

# Store params used to do auto-pagination
# $1 => approx record size
# $2 => header size
# $3 => array name
# $4 => name od marker (default: id)
setapilimit()
{
	RECSZ=$1
	HDRSZ=$2
	ARRNM=$3
	IDFIELD=${4:-id}
}

PARAMSTRING=""
setlimit()
{
	if [ -z "$APILIMIT" -a -n "$1" ]; then
		export PARAMSTRING="?limit=$1"
	elif [ "$APILIMIT" == "off" -o -z "$1" ]; then
		export PARAMSTRING=""
	elif ( echo $APILIMIT | grep -q "^[0-9]*$" ); then
		export PARAMSTRING="?limit=$APILIMIT"
	else
		echo "APILIMIT set to $APILIMIT which is neither off not an integer." 1>&2
		exit 1
	fi

	if  ( echo $APIOFFSET | grep -q "^[0-9]\+$" ); then
		if [ -z "PARAMSTRING" ]; then
			export PARAMSTRING="?start=$APIOFFSET"
		else
			export PARAMSTRING="$PARAMSTRING&start=$APIOFFSET"
		fi
	fi

	if [ -n "$APIMARKER" ]; then
		if [ -z "PARAMSTRING" ]; then
			export PARAMSTRING="?marker=$APIMARKER"
		else
			export PARAMSTRING="$PARAMSTRING&marker=$APIMARKER"
		fi
	fi

	while [ -n "$2" ]; do
		#echo $2
		if [ -z "PARAMSTRING" ]; then
			export PARAMSTRING="?$2"
		else
			export PARAMSTRING="$PARAMSTRING&$2"
		fi
		shift
	done
}

# Params: ARRNM Value [attr [id]]
find_id()
{
	ANM=${3:-name}
	IDN=${4:-id}
	#if test -n "$DEBUG"; then echo "jq '.'$1'[] | select(.'$ANM' == \"'$2'\") | .'$IDN | tr -d '\", '" 1>&2; fi
	jq '.'$1'[] | select(.'$ANM' == "'$2'") | .'$IDN | tr -d '", '
}

# Params: ARRNM Value addattr [match [attr [id]]]
find_id_ext()
{
	local ANM=${5:-name}
	local IDN=${6:-id}
	if test -n "$4"; then local FILT=" and .$3 == \"$4\""; fi
	#echo jq ".$1[] | select(.$ANM == \"$2\"$FILT) | .$IDN" 1>&2
	jq ".$1[] | select(.$ANM == \"$2\"$FILT) | .$IDN" | tr -d '", '
}

# Flatten array
arraytostr()
{
	sed -e 's@\["\([^"]*\)",@\1,@g' -e 's@,"\([^"]*\)",@ \1,@g' -e 's@\(,\| \[\)"\([^"]*\)"\]@ \2@g'
}

# convert functions
# $1: name
# $2: VPCID (optional)
convertSUBNETNameToId()
{
	#curlgetauth $TOKEN "$AUTH_URL_SUBNETS?limit=800"
	#SUBNETID=`curlgetauth $TOKEN "$AUTH_URL_SUBNETS" | jq '.subnets[] | select(.name == "'$1'") | .id' | tr -d '" ,'`
	#setlimit 800
	setlimit; setapilimit 360 20 subnets
	local SUBNETS=`curlgetauth_pag $TOKEN "$AUTH_URL_SUBNETS$PARAMSTRING"`
	local RC=$?
	SUBNETID=`echo "$SUBNETS" | find_id_ext subnets "$1" "vpc_id" "$2"`
	SUBNETAZ=`echo "$SUBNETS" | find_id_ext subnets "$1" "vpc_id" "$2" name availability_zone`
	if test -z "$SUBNETID"; then
		echo "ERROR: No subnet found by name $1" 1>&2
		exit 3
	fi
	if test "$SUBNETAZ" = "null"; then SUBNETAZ=""; fi
	export SUBNETID SUBNETAZ
	return $RC
}

convertVPCNameToId()
{
	#curlgetauth $TOKEN "$AUTH_URL_VPCS?limit=500"
	#VPCID=`curlgetauth $TOKEN "$AUTH_URL_VPCS?limit=500" | jq '.vpcs[] | select(.name == "'$1'") | .id' | tr -d '" ,'`
	#setlimit 500
	setlimit; setapilimit 320 20 vpcs
	VPCID=`curlgetauth_pag $TOKEN "$AUTH_URL_VPCS$PARAMSTRING" | find_id vpcs "$1"; return ${PIPESTATUS[0]}`
	local RC=$?
	if test -z "$VPCID"; then
		echo "ERROR: No VPC found by name $1" 1>&2
		exit 3
	fi
	#echo $VPCID
	export VPCID
	return $RC
}

convertSECUGROUPNameToId()
{
	unset IFS
	#SECUGROUP=`curlgetauth $TOKEN "$AUTH_URL_SEC_GROUPS" | jq '.security_groups[] | select(.name == "'$1'") | .id' | tr -d '" ,'`
	#SECUGROUP=`curlgetauth $TOKEN "$AUTH_URL_SEC_GROUPS" | find_id security_groups "$1"`
	#setlimit 500
	setlimit; setapilimit 4000 40 security_groups
	SECUGROUP=`curlgetauth_pag $TOKEN "$AUTH_URL_SEC_GROUPS$PARAMSTRING" | jq '.security_groups[] | select(.name == "'"$1"'") | .id' | tr -d '" ,'; return ${PIPESTATUS[0]}`
	local RC=$?
	if test `echo "$SECUGROUP" | wc -w` -gt 1; then
		SECUGROUP=`curlgetauth_pag $TOKEN "$AUTH_URL_SEC_GROUPS$PARAMSTRING" | jq '.security_groups[] | select(.name == "'"$1"'") | select(.vpc_id == "'"$VPCID"'") | .id' | tr -d '" ,'; return ${PIPESTATUS[0]}`
		RC=$?
	fi
	if test -z "$SECUGROUP"; then
		echo "ERROR: No security-group found by name $1" 1>&2
		exit 3
	fi
	if test `echo "$SECUGROUP" | wc -w` != 1; then
		echo "#Warning: Non-unique Security Group mapping: $1 -> $SECUGROUP" 1>&2
		SECUGROUP=`echo "$SECUGROUP" | head -n 1`
	fi
	export SECUGROUP
	return $RC
}

convertIMAGENameToId()
{
	#IMAGE_ID=`curlgetauth $TOKEN "$AUTH_URL_IMAGES" | jq '.images[] | select(.name == "'$IMAGENAME'") | .id' | tr -d '" ,'`
	#setlimit 800
	#setlimit; setapilimit 1600 100 images
	local FILT=""
	NAME="$(uriencode $1)"
	if [[ "$INSTANCE_TYPE" = "physical"* ]]; then
		FILT="&virtual_env_type=Ironic"
	elif [ -n "$INSTANCE_TYPE" ]; then
		FILT="&virtual_env_type=FusionCompute"
	fi
	IMAGE_ID=`curlgetauth $TOKEN "$AUTH_URL_IMAGES?name=$NAME$FILT" | find_id images "$1"; return ${PIPESTATUS[0]}`
	local RC=$?
	if test -z "$IMAGE_ID"; then
		echo "ERROR: No image found by name $1" 1>&2
		exit 3
	fi
	if test "$(echo "$IMAGE_ID" | wc -w)" != "1"; then
		IMAGE_ID=$(echo "$IMAGE_ID" | head -n1)
		echo "#Warning: Multiple images found by that name; using $IMAGE_ID" 1>&2
	fi
	#if test -n "$DEBUG"; then echo "Image ID: $IMAGE_ID" 1>&2; fi
	export IMAGE_ID
	return $RC
}

convertECSNameToId()
{
	#setlimit 1600
	#setlimit; setapilimit 420 40 servers id
	NAME="$(uriencode $1)"
	ECS_ID=`curlgetauth $TOKEN "$AUTH_URL_ECS?name=$NAME" | jq '.servers[] | select(.name == "'$1'") | .id' | tr -d '" ,'; return ${PIPESTATUS[0]}`
	local RC=$?
	if test -z "$ECS_ID"; then
		echo "ERROR: No VM found by name $1" 1>&2
		exit 3
	fi
	if test "$(echo "$ECS_ID" | wc -w)" != "1"; then
		ECS_ID=$(echo "$ECS_ID" | head -n1)
		echo "#Warning: Multiple VMs found by that name; using $ECS_ID" 1>&2
	fi
	export ECS_ID
	return $RC
}

convertEVSNameToId()
{
	#setlimit 1600
	#setlimit; setapilimit 400 30 volumes
	NAME="$(uriencode $1)"
	EVS_ID=`curlgetauth $TOKEN "$AUTH_URL_VOLS?name=$NAME" | jq '.volumes[] | select(.name == "'$1'") | .id' | tr -d '" ,'; return ${PIPESTATUS[0]}`
	local RC=$?
	if test -z "$EVS_ID"; then
		echo "ERROR: No volume found by name $1" 1>&2
		exit 3
	fi
	if test "$(echo "$EVS_ID" | wc -w)" != "1"; then
		EVS_ID=$(echo "$EVS_ID" | head -n1)
		echo "#Warning: Multiple volumes found by that name; using $EVS_ID" 1>&2
	fi
	export EVS_ID
	return $RC
}

convertBackupNameToId()
{
	#setlimit 1600
	#setlimit; setapilimit 1280 30 backups
	NAME="$(uriencode $1)"
	BACK_ID=`curlgetauth $TOKEN "$AUTH_URL_BACKS?name=$NAME" | jq '.backups[] | select(.name == "'$1'") | .id' | tr -d '" ,'; return ${PIPESTATUS[0]}`
	local RC=$?
	if test -z "$BACK_ID"; then
		echo "ERROR: No backup found by name $1" 1>&2
		exit 3
	fi
	if test "$(echo "$BACK_ID" | wc -w)" != "1"; then
		BACK_ID=$(echo "$BACK_ID" | head -n1)
		echo "#Warning: Multiple backups found by that name; using $BACK_ID" 1>&2
	fi
	export BACK_ID
	return $RC
}

convertBackupPolicyNameToId()
{
	#setlimit 800
	setlimit; setapilimit 320 40 backup_policies
	BACKPOL_ID=`curlgetauth_pag $TOKEN "$AUTH_URL_CBACKUPPOLS$PARAMSTRING" | jq '.backup_policies[] | select(.backup_policy_name == "'$1'") | .backup_policy_id' | tr -d '" ,'; return ${PIPESTATUS[0]}`
	local RC=$?
	if test -z "$BACKPOL_ID"; then
		echo "ERROR: No backup policy found by name $1" 1>&2
		exit 3
	fi
	if test "$(echo "$BACKPOL_ID" | wc -w)" != "1"; then
		BACKPOL_ID=$(echo "$BACKPOL_ID" | head -n1)
		echo "#Warning: Multiple backups found by that name; using $BACKPOL_ID" 1>&2
	fi
	export BACKPOL_ID
	return $RC
}

convertSnapshotNameToId()
{
	#setlimit 1600
	#setlimit; setapilimit 440 30 snapshots
	NAME="$(uriencode $1)"
	SNAP_ID=`curlgetauth $TOKEN "$AUTH_URL_SNAPS?name=$NAME" | jq '.snapshots[] | select(.name == "'$1'") | .id' | tr -d '" ,'; return ${PIPESTATUS[0]}`
	local RC=$?
	if test -z "$SNAP_ID"; then
		echo "ERROR: No snapshot found by name $1" 1>&2
		exit 3
	fi
	if test "$(echo "$SNAP_ID" | wc -w)" != "1"; then
		SNAP_ID=$(echo "$SNAP_ID" | head -n1)
		echo "#Warning: Multiple snapshots found by that name; using $SNAP_ID" 1>&2
	fi
	export SNAP_ID
	return $RC
}

convertEipToId()
{

	if test -n "$1"; then EIP="$1"; fi
	if is_uuid "$EIP"; then FILTER=".id == \"$EIP\""; else FILTER=".public_ip_address == \"$EIP\""; fi
	setlimit; setapilimit 400 30 publicips
	EIP_JSON=$(curlgetauth_pag $TOKEN "$AUTH_URL_PUBLICIPS$PARAMSTRING" | jq ".publicips[] | select($FILTER)"; return ${PIPESTATUS[0]})
	if test $? != 0 -o -z "$EIP_JSON" -o "$EIP_JSON" = "null"; then
		echo "ERROR: No Floating IP $EIP found" 1>&2
		exit 3
	fi
	EIP_ID=$(echo "$EIP_JSON" | jq '.id' | tr -d '"')
	EIP_IP=$(echo "$EIP_JSON" | jq '.public_ip_address' | tr -d '"')
	EIP_STATUS=$(echo "$EIP_JSON" | jq '.status' | tr -d '"')
	export EIP_ID EIP_STATUS
	return 0
}

handleCustom()
{
	local RC
	if test "$1" == "--paginate"; then PAGINATE="$2"; shift; shift; fi
	if test "$1" == "--jqfilter"; then JQFILTER="$2"; shift; shift; else JQFILTER="."; fi
	if test -n "$JQFILTER"; then JQ="jq -r \"$JQFILTER\""; else JQ="cat -"; fi
	if test "$1" == "--paginate"; then PAGINATE="$2"; shift; shift; fi
	METH=$1
	# NOTE: We better TRUST the caller not to pass in malicious things here
	#  so never call otc custom from a script that accepts non-sanitized args
	# TODO: Replace the knowledge of internal shell vars by a documented set
	#  the user can use here and do sed to fill in rather than eval.
	URL=$(eval echo "$2")
	if test $? != 0; then echo "ERROR evaluating URL $2 -> \"$URL\"" 1>&2; fi
	if test "${URL:0:1}" == "/"; then URL="$BASEURL$URL"; fi
	shift; shift
	ARGS=$(eval echo "$@")
	if test $? != 0; then echo "ERROR evaluating arguments $@ -> \"$ARGS\"" 1>&2; fi
	#TODO: Capture return code ...
	case "$METH" in
		GET)
			echo "#DEBUG: curl -X $METH $URL" 1>&2
			if test -n "$PAGINATE"; then
				setlimit; setapilimit 4000 40 $PAGINATE
				curlgetauth_pag $TOKEN "$URL" | eval "$JQ"
			else
				curlgetauth $TOKEN "$URL" | eval "$JQ"
			fi
			RC=${PIPESTATUS[0]}
			;;
		HEAD)
			echo "#DEBUG: curl -X $METH --head $URL" 1>&2
			RESP=$(curlheadauth $TOKEN "$URL")
			RC=$(echo "$RESP" | grep HTTP)
			echo "$RC"
			RC=$(echo "$RC" | sed 's@HTTP/[0-9\.]* \([0-9]*\).*$@\1@')
			#echo $RC
			test $RC -ge 200 -a $RC -le 299
			RC=$?
			;;
		PUT)
			echo "#DEBUG: curl -X $METH -d \"$ARGS\" $URL" 1>&2
			curlputauth $TOKEN "$ARGS" "$URL" | eval "$JQ"
			RC=${PIPESTATUS[0]}
			;;
		POST)
			echo "#DEBUG: curl -X $METH -d \"$ARGS\" $URL" 1>&2
			curlpostauth $TOKEN "$ARGS" "$URL" | eval "$JQ"
			RC=${PIPESTATUS[0]}
			;;
		PATCH)
			echo "#DEBUG: curl -X $METH -d \"$ARGS\" $URL" 1>&2
			curlpatchauth $TOKEN "$ARGS" "$URL" | eval "$JQ"
			RC=${PIPESTATUS[0]}
			;;
		DELETE)
			if test -z "$ARGS"; then
				echo "#DEBUG: curl -X $METH $URL" 1>&2
				curldeleteauth $TOKEN "$URL" | eval "$JQ"
				RC=${PIPESTATUS[0]}
			else
				echo "#DEBUG: curl -X $METH -d \"$ARGS\" $URL" 1>&2
				curldeleteauthwithjsonparameter $TOKEN "$ARGS" "$URL" | eval "$JQ"
				RC=${PIPESTATUS[0]}
			fi
			;;
		*)
			echo "ERROR: Unknown http method $METH in otc custom" 1>&2
			exit 1
			;;
	esac
	if test -z "$JQFILTER"; then echo; fi
	return $RC
}


getECSv2()
{
	if ! is_uuid "$1"; then convertECSNameToId "$1"; else ECS_ID="$1"; fi
	#X-OpenStack-Nova-API-Version: 2.26
	curlgetauth $TOKEN -H "X-OpenStack-Nova-API-Version: 2.26" "${NOVA_URL/v2/v2.1}/servers/$ECS_ID" | jq -r '.'
	return ${PIPESTATUS[0]}
}

getECSVM()
{
	if ! is_uuid "$1"; then convertECSNameToId "$1"; else ECS_ID="$1"; fi
	local ECSJSON IFACEJSON AUTOREC MYTAGS RC
	ECSJSON=`curlgetauth $TOKEN "$AUTH_URL_ECS/$ECS_ID" | jq -r '.[]'; exit ${PIPESTATUS[0]}`
	RC=$?
	if test $RC != 0; then echo "$ECSJSON"; return $RC; fi
	IFACEJSON=`curlgetauth $TOKEN "$AUTH_URL_ECS/$ECS_ID/os-interface" | jq -r '.[]'; exit ${PIPESTATUS[0]}`
	if test $? != 0; then
		IFACEJSON=""
	else
		IFACEJSON=", \"interfaceAttachments\": $IFACEJSON"
	fi
	AUTOREC=$(QUIETERR=1 curlgetauth $TOKEN "$AUTH_URL_ECS_CLOUD/$ECS_ID/autorecovery")
	if test $? != 0 || ! echo "$AUTOREC" | grep 'support_auto' >/dev/null 2>&1; then
		AUTOREC=""
	else
		AUTOREC=", \"autorecovery\": $AUTOREC"
	fi
	MYTAGS=$(curlgetauth $TOKEN "$AUTH_URL_ECS/$ECS_ID/tags")
	if test $? != 0; then # -o "$MYTAGS" == '{"tags": []}'; then
		MYTAGS=""
	else
		MYTAGS="${MYTAGS%\}}"
		MYTAGS=", ${MYTAGS#\{}"
	fi
	echo "{ \"server\": $ECSJSON $IFACEJSON $AUTOREC $MYTAGS }" | jq -r '.'
	return $RC
}

getShortECSList()
{
	local VM_FILTER=$(concatarr "&" "$@")
	VM_FILTER="${VM_FILTER// /%20}"
	#curlgetauth $TOKEN "$AUTH_URL_ECS?limit=1600" | jq -r  '.servers[] | .id+"   "+.name'
	#setlimit 1600
	setlimit; setapilimit 420 40 servers id
   if test -z "$PARAMSTRING" -a -n "$VM_FILTER"; then VM_FILTER="?${VM_FILTER:1}"; fi
	curlgetauth_pag $TOKEN "$AUTH_URL_ECS$PARAMSTRING$VM_FILTER" | jq -r  '.servers[] | .id+"   "+.name'
	return ${PIPESTATUS[0]}
}

getECSList()
{
	local VM_FILTER=$(concatarr "&" "$@")
	VM_FILTER="${VM_FILTER// /%20}"
	#curlgetauth $TOKEN "$AUTH_URL_ECS?limit=1200" | jq -r  '.servers[] | {id: .id, name: .name} | .id+"   "+.name'
	#setlimit 1200
	setlimit; setapilimit 2000 40 servers id
   if test -z "$PARAMSTRING" -a -n "$VM_FILTER"; then VM_FILTER="?${VM_FILTER:1}"; fi
	curlgetauth_pag $TOKEN "$AUTH_URL_ECS_DETAIL$PARAMSTRING$VM_FILTER" | jq -r  'def adr(a): [a[]|.[]|{addr}]|[.[].addr]|tostring; .servers[] | {id: .id, name: .name, status: .status, flavor: .flavor.id, az: .["OS-EXT-AZ:availability_zone"], addr: .addresses} | .id+"   "+.name+"   "+.status+"   "+.flavor+"   "+.az+"   "+adr(.addr) ' | arraytostr
       return ${PIPESTATUS[0]}
}


getECSListWithTags()
{
        local VM_FILTER=$(concatarr "&" "$@")
        VM_FILTER="${VM_FILTER// /%20}"
        #curlgetauth $TOKEN "$AUTH_URL_ECS?limit=1200" | jq -r  '.servers[] | {id: .id, name: .name} | .id+"   "+.name'
        #setlimit 1200
        setlimit; setapilimit 2000 40 servers id
   if test -z "$PARAMSTRING" -a -n "$VM_FILTER"; then VM_FILTER="?${VM_FILTER:1}"; fi
        vmtemp=`curlgetauth_pag $TOKEN "$AUTH_URL_ECS_DETAIL$PARAMSTRING$VM_FILTER" | jq -r  'def adr(a): [a[]|.[]|{addr}]|[.[].addr]|tostring; .servers[] | {id: .id, name: .name, status: .status, flavor: .flavor.id, az: .["OS-EXT-AZ:availability_zone"], addr: .addresses} | .id+"   "+.name+"   "+.status+"   "+.flavor+"   "+.az+"   "+adr(.addr) ' | arraytostr`
#IFS='\n'

         while read -r line; do
            myid=`echo $line | awk '{print $1}'`
            tag=`curlgetauth $TOKEN "$AUTH_URL_ECS/$myid/tags" | jq '.tags'|tr '\n' ' '|tr -d '[:space:]'`
            echo "$line $tag"
         done <<< "$vmtemp"
         return ${PIPESTATUS[0]}
}

getECSDetails()
{
	#setlimit 1200
	setlimit; setapilimit 2000 40 servers id
	if test -n "$1"; then
		if is_uuid "$1"; then
			curlgetauth $TOKEN "$AUTH_URL_ECS/$1" | jq '.server'
			#curlgetauth_pag $TOKEN "$AUTH_URL_ECS_DETAIL" | jq '.servers[] | select (.id == "'$1'")'
		else
			curlgetauth_pag $TOKEN "$AUTH_URL_ECS_DETAIL$PARAMSTRING" | jq '.servers[] | select (.name|test("'$1'"))'
		fi
	else
		curlgetauth_pag $TOKEN "$AUTH_URL_ECS_DETAIL$PARAMSTRING" | jq '.servers[]'
	fi
	return ${PIPESTATUS[0]}
}

getECSDetail()
{
	getECSDetails "$1" | jq '{VM: .name, ID: .id, Detail: .}'
	return ${PIPESTATUS[0]}
}

getECSDetailsNew()
{
	local RESP
	RESP=$(getECSDetails "$1")
	RC=$?
	echo "# VMID                                       name          status      AZ      SSHKeyName    Flavor      Image     Volumes   Nets   SGs"
	echo "$RESP" | jq -r  'def adr(a): [a[]|.[]|{addr}]|[.[].addr]|tostring; def vol(v): [v[]|{volid:.id}]|[.[].volid]|tostring; def sg(s): [s[]|{sgid:.name}]|[.[].sgid]|tostring; {id: .id, name: .name, status: .status, az: .["OS-EXT-AZ:availability_zone"], flavor: .flavor.id, sshkey: .key_name, addr: .addresses, image: .image.id, volume: .["os-extended-volumes:volumes_attached"], sg: .security_groups } | .id + "   " + .name + "   " + .status + "   " + .az + "   " + .sshkey + "   " + .flavor + "   " + .image + "   " + vol(.volume) + "   " + adr(.addr) + "   " + sg(.sg)' | arraytostr
	# TODO: Volume IDs into names, SG names
	# Add FloatingIP info
	return $RC
}

getLimits()
{
	curlgetauth $TOKEN "$AUTH_URL_ECS_CLOUD/limits" | jq '.'
	return ${PIPESTATUS[0]}
}

getAZList()
{
	curlgetauth $TOKEN "$NOVA_URL/os-availability-zone" | jq  '.availabilityZoneInfo[] | {znm: .zoneName, avl: .zoneState.available} | .znm' | tr -d '"'
	return ${PIPESTATUS[0]}
}

getAZDetail()
{
	curlgetauth $TOKEN "$NOVA_URL/os-availability-zone/$1" | jq  '.'
	return ${PIPESTATUS[0]}
}


getVPCList()
{
	#setlimit 500
	setlimit; setapilimit 320 20 vpcs
	curlgetauth_pag $TOKEN "$AUTH_URL_VPCS$PARAMSTRING" | jq -r '.vpcs[] | {id: .id, name: .name, status: .status, cidr: .cidr} | .id +"   " +.name    +"   " +.status   +"   " +.cidr  '
#| python -m json.tool
	return ${PIPESTATUS[0]}
}

getVPCDetail()
{
	if ! is_uuid "$1"; then convertVPCNameToId "$1"; else VPCID="$1"; fi
	curlgetauth $TOKEN "$AUTH_URL_VPCS/$VPCID" | jq -r '.'
	return ${PIPESTATUS[0]}
	# FIXME: Add tag display?
}

getVPCDetail2()
{
	if ! is_uuid "$1"; then convertVPCNameToId "$1"; else VPCID="$1"; fi
	curlgetauth $TOKEN "$AUTH_URL_ROUTER/$VPCID" | jq -r '.'
	return ${PIPESTATUS[0]}
	# FIXME: Add tag display?
}

getVPCRoutes()
{
	local SEP="   "
	if test "$1" == "--via"; then SEP=" via "; shift; fi
	if ! is_uuid "$1"; then convertVPCNameToId "$1"; else VPCID="$1"; fi
	if test "$2" == "--via"; then SEP=" via "; fi
	curlgetauth $TOKEN "$AUTH_URL_ROUTER/$VPCID" | jq -r ".router.routes[] | .destination+\"$SEP\"+.nexthop"
	return ${PIPESTATUS[0]}
}

addVPCRoute()
{
	if ! is_uuid "$1"; then convertVPCNameToId "$1"; else VPCID="$1"; fi
	if test "$2" == "0/0"; then DEST="0.0.0.0/0"; else DEST="$2"; fi
	if test "$3" == "via"; then shift; fi
	if test -z "$3"; then echo "ERROR: Need to specify dest and nexthop" 1>&2; exit 2; fi
	ROUTE="{ \"router\": {
	\"routes\": [ {
		\"destination\": \"$DEST\",
		\"nexthop\": \"$3\"
	} ] } }"
	curlputauth $TOKEN "$ROUTE" "$AUTH_URL_ROUTER/$VPCID" | jq -r '.'
	return ${PIPESTATUS[0]}
}

deleteVPCRoute()
{
	if ! is_uuid "$1"; then convertVPCNameToId "$1"; else VPCID="$1"; fi
	if test "$2" == "0/0"; then DEST="0.0.0.0/0"; else DEST="$2"; fi
	#if test -z "$3"; then echo "ERROR: Need to specify dest and nexthop" 1>&2; exit 2; fi
	# FIXME: We currently assume that we can just delete all routes ...
	# As of 2017-05, only one 0/0 route is supported by OTC, so it's fine
	# As soon as more routes can be configured, we would have to query all routes,
	# look for the one matching the to be deleted route and then put the remaining
	ROUTE="{ \"router\": {
	\"routes\": [ ] } }"
	curlputauth $TOKEN "$ROUTE" "$AUTH_URL_ROUTER/$VPCID" | jq -r '.'
	return ${PIPESTATUS[0]}
}

switchVPCSNAT()
{
	if ! is_uuid "$1"; then convertVPCNameToId "$1"; else VPCID="$1"; fi
	EGW=$(curlgetauth $TOKEN "$AUTH_URL_ROUTER/$VPCID" | jq -r '.router.external_gateway_info.network_id')
   RC=${PIPESTATUS[0]}
	if test $RC != 0; then return $RC; fi
   SNAT="{ \"router\": {
		\"external_gateway_info\": {
			\"network_id\": \"$EGW\",
			\"enable_snat\": $2
		}
	}
}"
   curlputauth $TOKEN "$SNAT" "$AUTH_URL_ROUTER/$VPCID" | jq -r '.'
	return ${PIPESTATUS[0]}
}

enableVPCSNAT()
{
	switchVPCSNAT $1 true
}

disableVPCSNAT()
{
	switchVPCSNAT $1 false
}

VPCDelete()
{
	if ! is_uuid "$1"; then convertVPCNameToId "$1"; else VPCID="$1"; fi
	curldeleteauth $TOKEN "$AUTH_URL_VPCS/$VPCID"
	local RC=$?
	#echo
	return $RC
}

getVPCLimits()
{
	curlgetauth $TOKEN "${AUTH_URL_VPCS%vpcs}quotas" | jq -r 'def str(s): s|tostring; .quotas.resources[] | .type+"   "+str(.used)+"/"+str(.quota)'
	return ${PIPESTATUS[0]}
}

getVPCPeerList()
{
	local FILTER
	while test -n "$1"; do FILTER="$FILTER&$(uriencodenoteq $1)"; shift; done
	FILTER=${FILTER/&/?}
	#setlimit; setapilimit 320 20 vpcs
	curlgetauth $TOKEN "$NEUTRON_URL/v2.0/vpc/peerings$FILTER" | jq -r '.peerings[] | .id+"   "+.name+"   "+.status+"   "+.request_vpc_info.vpc_id+"   "+.accept_vpc_info.vpc_id+"   "+.request_vpc_info.tenant_id+"   "+.accept_vpc_info.tenant_id'
	return ${PIPESTATUS[0]}
}

getVPCPeerDetail()
{
	ID=$1
	if ! is_uuid "$1"; then NM="$(uriencode $1)"; ID=$(curlgetauth $TOKEN "$NEUTRON_URL/v2.0/vpc/peerings?name=$NM" | jq .peerings[].id | tr -d '"'); fi
	if ! is_uuid "$ID"; then echo "ERROR: Peering $1 not found" 1>&2; fi
	curlgetauth $TOKEN "$NEUTRON_URL/v2.0/vpc/peerings/$ID" | jq -r '.'
	return ${PIPESTATUS[0]}
}

deleteVPCPeer()
{
	ID=$1
	if ! is_uuid "$1"; then NM="$(uriencode $1)"; ID=$(curlgetauth $TOKEN "$NEUTRON_URL/v2.0/vpc/peerings?name=$NM" | jq .peerings[].id | tr -d '"'); fi
	if ! is_uuid "$ID"; then echo "ERROR: Peering $1 not found" 1>&2; fi
	curldeleteauth $TOKEN "$NEUTRON_URL/v2.0/vpc/peerings/$ID"
}

createVPCPeer()
{
	local RVPC AVPC REQ TENID RV AV
	RVPC="$1"
	AVPC="$2"
	if test -z "$NAME"; then RV="${RVPC#vpc-}"; RV="${RV#VPC-}"; AV="${AVPC#vpc-}"; AV="${AV#VPC-}"; NAME="peering-$RV-$AV"; fi
	#if ! is_uuid "$RVPC"; then RVPC=$(curlgetauth $TOKEN $NEUTRON_URL/v2.0/routers?name=$(uriencode $RVPC) | jq .routers[].id | tr -d '"'); fi
	if ! is_uuid "$RVPC"; then convertVPCNameToId "$RVPC"; RVPC=$VPCID; fi
	#if ! is_uuid "$AVPC"; then AVPC=$(curlgetauth $TOKEN $NEUTRON_URL/v2.0/routers?name=$(uriencode $AVPC) | jq .routers[].id | tr -d '"'); fi
	if ! is_uuid "$AVPC"; then convertVPCNameToId "$AVPC"; AVPC=$VPCID; fi
	if test -z "$RVPC" -o "$RVPC" = "null"; then echo "ERROR: VPC $1 not found" 1>&2; exit 2; fi
	if test -z "$AVPC" -o "$AVPC" = "null"; then echo "ERROR: VPC $2 not found" 1>&2; exit 2; fi
	if test -n "$PROJECTID"; then TENID=", \"tenant_id\": \"$PROJECTID\" "; fi
	REQ="{
	\"peering\": {
		\"name\": \"$NAME\",
		\"request_vpc_info\": {
			\"vpc_id\": \"$RVPC\"
		},
		\"accept_vpc_info\": {
			\"vpc_id\": \"$AVPC\"$TENID
		}
	}
}"
	curlpostauth $TOKEN "$REQ" "$NEUTRON_URL/v2.0/vpc/peerings" | jq -r '.'
	return ${PIPESTATUS[0]}
}

updateVPCPeer()
{
	ID=$1
	if ! is_uuid "$1"; then NM="$(uriencode $1)"; ID=$(curlgetauth $TOKEN "$NEUTRON_URL/v2.0/vpc/peerings?name=$NM" | jq .peerings[].id | tr -d '"'); fi
	if ! is_uuid "$ID"; then echo "ERROR: Peering $1 not found" 1>&2; exit 2; fi
	if test -z "$NAME"; then echo "ERROR: Need to specify --name" 1>&2; exit 2; fi
	curlputauth "$TOKEN" "{ \"peering\": { \"name\": \"$NAME\" } }" "$NEUTRON_URL/v2.0/vpc/peerings/$ID" | jq -r '.'
	return ${PIPESTATUS[0]}
}

acceptVPCPeer()
{
	ID=$1
	if ! is_uuid "$1"; then NM="$(uriencode $1)"; ID=$(curlgetauth $TOKEN "$NEUTRON_URL/v2.0/vpc/peerings?name=$NM" | jq .peerings[].id | tr -d '"'); fi
	if ! is_uuid "$ID"; then echo "ERROR: Peering $1 not found" 1>&2; exit 2; fi
	curlputauth "$TOKEN" "" "$NEUTRON_URL/v2.0/vpc/peerings/$ID/accept" | jq -r '.'
	return ${PIPESTATUS[0]}
}

rejectVPCPeer()
{
	ID=$1
	if ! is_uuid "$1"; then NM="$(uriencode $1)"; ID=$(curlgetauth $TOKEN "$NEUTRON_URL/v2.0/vpc/peerings?name=$NM" | jq .peerings[].id | tr -d '"'); fi
	if ! is_uuid "$ID"; then echo "ERROR: Peering $1 not found" 1>&2; exit 2; fi
	curlputauth "$TOKEN" "" "$NEUTRON_URL/v2.0/vpc/peerings/$ID/reject" | jq -r '.'
	return ${PIPESTATUS[0]}
}

convertEIPtoID()
{
	#setlimit; setapilimit 400 30 publicips
	#curlgetauth_pag $TOKEN "$AUTH_URL_PUBLICIPS$PARAMSTRING" | jq ".publicips[] | select(.public_ip_address == "$1") | .id" | tr -d '"'
	EIP_RESP=$(curlgetauth $TOKEN "$AUTH_URL_PUBLICIPS?public_ip_address=$1")
	if test $? != 0; then echo "ERROR: No such EIP $1" 1>&2; exit 2; fi
	EIP=$(echo "$EIP_RESP" | jq '.publicips[].id' | tr -d '"')
	BWID=$(echo "$EIP_RESP" | jq '.publicips[].bandwidth_id' | tr -d '"')
	#EIP_RESP=$(curlgetauth $TOKEN "$NEUTRON_URL/v2.0/floatingips?floating_ip_address=$1")
	#if test $? != 0; then echo "ERROR: No such EIP $1" 1>&2; exit 2; fi
	#EIP=$(echo "$EIP_RESP" | jq '.floatingips[].id' | tr -d '"')
}

getPUBLICIPSList()
{
	#curlgetauth $TOKEN "$AUTH_URL_PUBLICIPS?limit=500" | jq '.'
	#setlimit 500
	setlimit; setapilimit 400 30 publicips
	#curlgetauth_pag $TOKEN "$NEUTRON_URL/v2.0/floatingips$PARAMSTRING" | jq '.floatingips[]  | .id +"   " +.floating_ip_address +"   " +.status+"   " +.fixed_ip_address +"   "+.router_id' | tr -d '"'
	curlgetauth_pag $TOKEN "$AUTH_URL_PUBLICIPS$PARAMSTRING" | jq 'def str(v): v|tostring; .publicips[]  | .id +"   " +.public_ip_address +"   " +.status+"   " +.private_ip_address +"   " +str(.bandwidth_size) +"   " +.bandwidth_share_type ' | tr -d '"'
	return ${PIPESTATUS[0]}
}

getPUBLICIPSDetail()
{
	if ! is_uuid "$1" && is_ip4 $1; then convertEIPtoID $1; else EIP=$1; fi
	curlgetauth $TOKEN "$AUTH_URL_PUBLICIPS/$EIP" | jq '.'
	return ${PIPESTATUS[0]}
}

getSECGROUPListDetail()
{
	FILTER=$(concatarr "&" "$@")
	FILTER="${FILTER// /%20}"
	#setlimit 500
	setlimit; setapilimit 4000 40 security_groups
   if test -z "$PARAMSTRING" -a -n "$FILTER"; then FILTER="?${FILTER:1}"; fi
   # V1 Huawei API - filtering not working
	curlgetauth_pag $TOKEN "$AUTH_URL_SEC_GROUPS$PARAMSTRING$FILTER" | jq '.[]'
	return ${PIPESTATUS[0]}
}

getSECGROUPList()
{
	FILTER=$(concatarr "&" "$@")
	FILTER="${FILTER// /%20}"
	#setlimit 500
	setlimit; setapilimit 4000 40 security_groups
   if test -z "$PARAMSTRING" -a -n "$FILTER"; then FILTER="?${FILTER:1}"; fi
   # V1 Huawei API - filtering not working
	curlgetauth_pag $TOKEN "$AUTH_URL_SEC_GROUPS$PARAMSTRING$FILTER" | jq '.security_groups[] | {id: .id, name: .name, vpc: .vpc_id} | .id +"   " +.name+"   "+.vpc' | tr -d '"'
	return ${PIPESTATUS[0]}
}

getSECGROUPRULESListOld()
{
	curlgetauth $TOKEN "$AUTH_URL_SEC_GROUP_RULES" | jq '.[]'
	return ${PIPESTATUS[0]}
}

getSECGROUPRULESList()
{
	if ! is_uuid "$1"; then convertSECUGROUPNameToId "$1"; else SECUGROUP="$1"; fi
	#setlimit 800
	setlimit; setapilimit 4000 40 security_groups
	curlgetauth_pag $TOKEN "$AUTH_URL_SEC_GROUPS$PARAMSTRING" | jq '.security_groups[] | select(.id == "'$SECUGROUP'")'
	return ${PIPESTATUS[0]}
}

SECGROUPCreate()
{
	if test -z "$SECUGROUPNAME" -a -n "$1"; then SECUGROUPNAME="$1"; fi
	if test -n "$VPCID"; then VPCJSON=", \"vpc_id\": \"$VPCID\""; fi
	local DESCJSON=""
	if test -n "$DESCRIPTION"; then DESCJSON=", \"description\": \"$DESCRIPTION\""; fi
	local REQ_CREATE_SECGROUP="{ \"security_group\": { \"name\": \"$SECUGROUPNAME\"$VPCJSON $DESCJSON } }"
	if test -n "$DEBUG"; then echo $REQ_CREATE_SECGROUP 1>&2; fi
	SGOUT=$(curlpostauth "$TOKEN" "$REQ_CREATE_SECGROUP" "$AUTH_URL_SEC_GROUPS")
	RC=$?
	if test -n "$DESCRIPTION"; then
		SGID=$(echo "$SGOUT" | jq '.[] | .id' | tr -d '"')
		OUT=$(curlputauth $TOKEN "{ \"security_group\": { \"description\": \"$DESCRIPTION\" } }" "$NEUTRON_URL/v2.0/security-groups/$SGID")
		SGOUT=$(echo "$SGOUT" | sed "s/\"description\":\"[^\"]*\"/\"description\":\"$DESCRIPTION\"/")
	fi
	echo "$SGOUT" | jq '.[]'
	return ${PIPESTATUS[0]}
}

SECGROUPDelete()
{
	if ! is_uuid "$1"; then convertSECUGROUPNameToId "$1"; else SECUGROUP="$1"; fi
	curldeleteauth "$TOKEN" "$NEUTRON_URL/v2.0/security-groups/$SECUGROUP"
	#return $?
}

SECGROUPRULECreate()
{
	if test -n "$REMGROUPID" && ! is_uuid "$REMGROUPID"; then
		OLDSG="$SECUGROUP"; convertSECUGROUPNameToId "$REMGROUPID"
		REMGROUPID="$SECUGROUP"; SECUGROUP="$OLDSG"
	fi
	if test -n "$REMGROUPID"; then
		REMOTE="\"remote_group_id\": \"$REMGROUPID\","
	elif test -n "$REMIP"; then
		REMOTE="\"remote_ip_prefix\": \"$REMIP\","
	fi
	if test -n "$DESCRIPTION"; then
		DESCJSON="\"description\": \"$DESCRIPTION\","
	fi
	local REQ_CREATE_SECGROUPRULE='{
		"security_group_rule": {
			'$DESCJSON'
			"direction":"'"$DIRECTION"'",
			"port_range_min":"'"$PORTMIN"'",
			"port_range_max":"'"$PORTMAX"'",
			"ethertype":"'"$ETHERTYPE"'",
			"protocol":"'"$PROTOCOL"'",
			'$REMOTE'
			"security_group_id":"'"$SECUGROUP"'"
		}
	}'
	#{"security_group_rule":{ "direction":"'"$DIRECTION"'", "port_range_min":"'"$PORTMIN"'", "ethertype":"'"$ETHERTYPE"'", "port_range_max":"'"$PORTMAX"'", "protocol":"'"$PROTOCOL"'", "remote_group_id":"'"$REMOTEGROUPID"'", "security_group_id":"'"$SECUGROUPID"'" } }
	#{"security_group_rule":{ "direction":"ingress", "port_range_min":"80", "ethertype":"IPv4", "port_range_max":"80", "protocol":"tcp", "remote_group_id":"85cc3048-abc3-43cc-89b3-377341426ac5", "security_group_id":"a7734e61-b545-452d-a3cd-0189cbd9747a" } }
	if test -n "$DEBUG"; then echo $REQ_CREATE_SECGROUPRULE 1>&2; fi
	curlpostauth "$TOKEN" "$REQ_CREATE_SECGROUPRULE" "$AUTH_URL_SEC_GROUP_RULES" | jq '.[]'
	return ${PIPESTATUS[0]}
}

getEVSListOTC()
{
	FILTER=$(concatarr "&" "$@")
	FILTER="${FILTER// /%20}"
	#curlgetauth $TOKEN "$AUTH_URL_CVOLUMES?limit=1200" | jq '.volumes[] | {id: .id, name: .name} | .id +"   " +.name ' | tr -d '"'
	#setlimit 1200
	setlimit; setapilimit 2400 30 volumes
   if test -z "$PARAMSTRING" -a -n "$FILTER"; then FILTER="?${FILTER:1}"; fi
	curlgetauth_pag $TOKEN "$AUTH_URL_CVOLUMES/detail$PARAMSTRING$FILTER" | jq 'def att(a): [a[0]|{id:.server_id, dev:.device}]|.[]|.id+":"+.dev; def str(v): v|tostring; .volumes[] | .id +"   " +.name+"   "+.status+"   "+.type+"   "+str(.size)+"   "+.availability_zone+"   "+att(.attachments) ' | tr -d '"'
	return ${PIPESTATUS[0]}
}

getEVSList()
{
	FILTER=$(concatarr "&" "$@")
	FILTER="${FILTER// /%20}"
	#setlimit 1600
	setlimit; setapilimit 400 30 volumes
   if test -z "$PARAMSTRING" -a -n "$FILTER"; then FILTER="?${FILTER:1}"; fi
	curlgetauth_pag $TOKEN "$AUTH_URL_VOLS$PARAMSTRING$FILTER" | jq '.volumes[] | {id: .id, name: .name} | .id +"   " +.name ' | tr -d '"'
	#curlgetauth $TOKEN "$AUTH_URL_VOLS/details?limit=1200" | jq '.volumes[] | {id: .id, name: .name, status: .status, type: .volume_type, size: .size|tostring, az: .availability_zone} | .id +"   " +.name+"   "+.status+"   "+.type+"   "+.size+"   "+.az ' | tr -d '"'
	return ${PIPESTATUS[0]}
}

getEVSDetail()
{
	if ! is_uuid "$1"; then convertEVSNameToId "$1"; else EVS_ID="$1"; fi
	#curlgetauth $TOKEN "$AUTH_URL_CVOLUMES_DETAILS?limit=1200" | jq '.volumes[] | select(.id == "'$EVS_ID'")'
	curlgetauth $TOKEN "$AUTH_URL_VOLS/$EVS_ID" | jq '.volume'
	return ${PIPESTATUS[0]}
}

getEVSTags()
{
	if ! is_uuid "$1"; then convertEVSNameToId "$1"; else EVS_ID="$1"; fi
	#curlgetauth $TOKEN "$AUTH_URL_CVOLUMES_DETAILS?limit=1200" | jq '.volumes[] | select(.id == "'$EVS_ID'")'
	curlgetauth $TOKEN "$CINDER_URL/os-vendor-tags/volumes/$EVS_ID" | jq '.tags'
	return ${PIPESTATUS[0]}
}

getEVSDetailExt()
{
	if ! is_uuid "$1"; then convertEVSNameToId "$1"; else EVS_ID="$1"; fi
	TAGS=`curlgetauth $TOKEN "${AUTH_URL_VOLS%/volumes}/os-vendor-tags/volumes/$EVS_ID"`
	local RC=$?
	TAGS="${TAGS#\{}"; TAGS="${TAGS%\}}"
	if test -n "$TAGS"; then TAGS=",\n  $TAGS"; fi
	setlimit; setapilimit 2400 30 volumes
	curlgetauth_pag $TOKEN "$AUTH_URL_CVOLUMES_DETAILS$PARAMSTRING" | jq '.volumes[] | select(.id == "'$EVS_ID'")' | sed "s/^  }$/  }$TAGS/" | jq -r '.'
	#curlgetauth $TOKEN "$AUTH_URL_VOLS/$EVS_ID" | jq '.volume'
	return $(($RC+${PIPESTATUS[0]}))
}

getSnapshotList()
{
	FILTER=$(concatarr "&" "$@")
	FILTER="${FILTER// /%20}"
	#setlimit 1200
	setlimit; setapilimit 440 30 snapshots
   if test -z "$PARAMSTRING" -a -n "$FILTER"; then FILTER="?${FILTER:1}"; fi
	curlgetauth_pag $TOKEN "$AUTH_URL_SNAPS$PARAMSTRING$FILTER" | jq '.snapshots[] | {id: .id, name: .name, status: .status, upd: .updated_at} | .id +"   " +.name +"   "+.status+"   "+.upd ' | tr -d '"' | sed 's/\(T[0-9:]*\)\.[0-9]*$/\1/'
	return ${PIPESTATUS[0]}
}

getSnapshotDetail()
{
	if ! is_uuid "$1"; then convertSnapshotNameToId "$1"; else SNAP_ID="$1"; fi
	curlgetauth $TOKEN "$AUTH_URL_SNAPS/$SNAP_ID" | jq '.snapshot'
	return ${PIPESTATUS[0]}
}

deleteSnapshot()
{
	if ! is_uuid "$1"; then convertSnapshotNameToId "$1"; else SNAP_ID="$1"; fi
	curldeleteauth $TOKEN "$AUTH_URL_SNAPS/$SNAP_ID" | jq '.'
	return ${PIPESTATUS[0]}
}

getBackupPolicyList()
{
	#setlimit 800
	setlimit; setapilimit 320 40 backup_policies
	curlgetauth_pag $TOKEN "$AUTH_URL_CBACKUPPOLS$PARAMSTRING" | jq 'def tostr(v): v|tostring; .backup_policies[] | .backup_policy_id+"   "+.backup_policy_name+"   "+.scheduled_policy.status+"   "+tostr(.policy_resource_count)+"   "+.scheduled_policy.start_time+"   "+tostr(.scheduled_policy.frequency)+"   "+tostr(.scheduled_policy.rentention_num)+"   "+.scheduled_policy.remain_first_backup_of_curMonth' | tr -d '"'
	return ${PIPESTATUS[0]}
}

getBackupPolicyDetail()
{
	#setlimit 800
	setlimit; setapilimit 320 40 backup_policies
	local filter
	if test -n "$1"; then
		if ! is_uuid "$1"; then filter="| select(.backup_policy_name == \"$1\")"; else filter="| select(.backup_policy_id == \"$1\")"; fi
	fi
	curlgetauth_pag $TOKEN "$AUTH_URL_CBACKUPPOLS$PARAMSTRING" | jq ".backup_policies[] $filter"
	return ${PIPESTATUS[0]}
}

createBackupPolicy()
{
	local NAME="$1"; shift
	# Optional pos params (convenience)
	if test -z "$BKUPTIME" -a -n "$1"; then if "$1" == "--time"; then shift; fi; BKUPTIME="$1";
		if test -z "$BKUPFREQ" -a -n "$2"; then if test "$2" == "--freq"; then shift; fi; BKUPFREQ=$2;
			if test -z "$BKUPRETAIN" -a -n "$3"; then if test "$3" == "--retain"; then shift; fi; BKUPRETAIN=$3; fi
		fi
	fi
	if test -z "$BKUPRETAIN" -o -z "$BKUPFREQ" -o -z "$BKUPTIME"; then
		echo "ERROR: backuppolicy needs --time, --freq and --retain" 1>&2; exit 2
	fi
	local OPTSTR
	if test -z "$BKUPRETFIRST"; then echo "WARN: BackupPolicy: Default to retain 1st backup of cur month" 1>&2; BKUPRETFIRST="Y"; fi
	if test -z "$OPTENABLE" -a -z "$OPTDISABLE"; then OPTENABLE=1; fi
	if test -n "$OPTENABLE"; then OPTSTR=", \"status\": \"ON\""; else OPTSTR=", \"status\": \"OFF\""; fi
	if test -n "$TAGS"; then OPTSTR2=", \"tags\": [ $(keyval2keyvalue $TAGS) ]"; fi
	# "reNtention" is not a bug in the tool, but the API :-O
	curlpostauth $TOKEN "{ \"backup_policy_name\": \"$NAME\", \"scheduled_policy\": { \"start_time\": \"$BKUPTIME\", \"frequency\": $BKUPFREQ, \"rentention_num\": $BKUPRETAIN, \"remain_first_backup_of_curMonth\": \"$BKUPRETFIRST\"$OPTSTR } $OPTSTR2 }" "$AUTH_URL_CBACKUPPOLS" | jq -r '.'
	return ${PIPESTATUS[0]}
}

updateBackupPolicy()
{
	BACKPOL_ID="$1"; shift
	if ! is_uuid $BACKPOL_ID; then convertBackupPolicyNameToId $BACKPOL_ID; fi
	local POL=""
	if test -n "$NAME"; then NM="\"backup_policy_name\": \"$NAME\","; fi
	if test -n "$BKUPTIME"; then POL="$POL, \"start_time\": \"$BKUPTIME\""; fi
	if test -n "$BKUPFREQ"; then POL="$POL, \"frequency\": $BKUPFREQ"; fi
	if test -n "$BKUPRETAIN"; then POL="$POL, \"rentention_num\": $BKUPFREQ"; fi
	if test -n "$BKUPRETFIRST"; then POL="$POL, \"remain_first_backup_of_curMonth\": \"$BKUPRETFIRST\""; fi
	if test -n "$OPTENABLE"; then POL="$POL, \"status\": \"ON\""; fi
	if test -n "$OPTDISABLE"; then POL="$POL, \"status\": \"OFF\""; fi
	if test -n "$POL"; then POL="\"scheduled_policy\": { ${POL#,} }"; fi
	if test -z "$NM" -a -z "$POL"; then echo "ERROR: BackupPolicy update without any changes?" 1>&2; exit 2; fi
	curlputauth $TOKEN "{ $NM $POL }" "$AUTH_URL_CBACKUPPOLS/$BACKPOL_ID" | jq -r '.'
	return ${PIPESTATUS[0]}
}

deleteBackupPolicy()
{
	BACKPOL_ID="$1"; shift
	if ! is_uuid $BACKPOL_ID; then convertBackupPolicyNameToId $BACKPOL_ID; fi
	curldeleteauth $TOKEN "$AUTH_URL_CBACKUPPOLS/$BACKPOL_ID"
}

addVolsToPolicy()
{
	BACKPOL_ID="$1"; shift
	if ! is_uuid $BACKPOL_ID; then convertBackupPolicyNameToId $BACKPOL_ID; fi
	local RSRC=""
	for vol in "$@"; do
		if ! is_uuid "$vol"; then oldvol="$vol"; vol=`curlgetauth $TOKEN "$AUTH_URL_VOLS?name=$vol" | jq '.volumes[] | select(.name == "'$vol'") | .id' | tr -d '" ,'`; fi
		if ! is_uuid "$vol"; then echo "WARN: No such volume $oldvol" 1>&2; fi
		RSRC="$RSRC, { \"resource_id\": \"$vol\", \"resource_type\": \"volume\" }"
	done
	if test -z "$RSRC"; then echo "ERROR: Need to list volume IDs to be added to BackupPolicy" 1>&2; exit2; fi
	RSRC="\"resources\": [ ${RSRC#,} ]"
	curlpostauth $TOKEN "{ \"backup_policy_id\": \"$BACKPOL_ID\", $RSRC }" "${AUTH_URL_CBACKUPPOLS}resources" | jq -r '.'
	return ${PIPESTATUS[0]}
}

rmvVolsFromPolicy()
{
	BACKPOL_ID="$1"; shift
	if ! is_uuid $BACKPOL_ID; then convertBackupPolicyNameToId $BACKPOL_ID; fi
	local RSRC=""
	for vol in "$@"; do
		if ! is_uuid "$vol"; then oldvol="$vol"; vol=`curlgetauth $TOKEN "$AUTH_URL_VOLS?name=$vol" | jq '.volumes[] | select(.name == "'$vol'") | .id' | tr -d '" ,'`; fi
		if ! is_uuid "$vol"; then echo "WARN: No such volume $oldvol" 1>&2; fi
		RSRC="$RSRC, { \"resource_id\": \"$vol\" }"
	done
	if test -z "$RSRC"; then echo "ERROR: Need to list volume IDs to be removed from BackupPolicy" 1>&2; exit2; fi
	RSRC="\"resources\": [ ${RSRC#,} ]"
	# Ugh, POST for deleting objects :-(
	curlpostauth $TOKEN "{ $RSRC }" "${AUTH_URL_CBACKUPPOLS}resources/$BACKPOL_ID/deleted_resources" | jq -r '.'
	return ${PIPESTATUS[0]}
}

executeBackupPolicy()
{
	BACKPOL_ID="$1"; shift
	if ! is_uuid $BACKPOL_ID; then convertBackupPolicyNameToId $BACKPOL_ID; fi
	curlpostauth $TOKEN "" "$AUTH_URL_CBACKUPPOLS/$BACKPOL_ID/action"
}

showBackupPolicyTasks()
{
	BACKPOL_ID="$1"; shift
	if ! is_uuid $BACKPOL_ID; then convertBackupPolicyNameToId $BACKPOL_ID; fi
	curlgetauth $TOKEN $AUTH_URL_CBACKUPPOLS/$BACKPOL_ID/backuptasks | jq -r '.'
	return ${PIPESTATUS[0]}
}

listBackupPolicyTasks()
{
	BACKPOL_ID="$1"; shift
	if ! is_uuid $BACKPOL_ID; then convertBackupPolicyNameToId $BACKPOL_ID; fi
	curlgetauth $TOKEN $AUTH_URL_CBACKUPPOLS/$BACKPOL_ID/backuptasks | jq -r '.tasks[] | .job_id+"   "+.backup_name+"   "+.status+"   "+.resource_id+"   "+.created_at' | tr -d '"'
	return ${PIPESTATUS[0]}
}


getBackupList()
{
	FILTER=$(concatarr "&" "$@")
	FILTER="${FILTER// /%20}"
	#curlgetauth $TOKEN "$AUTH_URL_BACKS?limit=1200" | jq '.backups[] | {id: .id, name: .name} | .id +"   " +.name ' | tr -d '"'
	#setlimit 1200
	setlimit; setapilimit 1280 30 backups
   if test -z "$PARAMSTRING" -a -n "$FILTER"; then FILTER="?${FILTER:1}"; fi
	curlgetauth_pag $TOKEN "$AUTH_URL_BACKS/detail$PARAMSTRING$FILTER" | jq 'def str(v): v|tostring; .backups[] | .id +"   " +.name+"   "+.status+"   "+str(.size)+"   "+.availability_zone+"   "+.updated_at ' | tr -d '"' | sed 's/\(T[0-9:]*\)\.[0-9]*$/\1/'
	return ${PIPESTATUS[0]}
}

getBackupDetail()
{
	if ! is_uuid "$1"; then convertBackupNameToId "$1"; else BACK_ID="$1"; fi
	curlgetauth $TOKEN "$AUTH_URL_BACKS/$BACK_ID" | jq '.backup'
	return ${PIPESTATUS[0]}
}

deleteBackupOTC()
{
	local BACKUP
	if ! is_uuid "$1"; then convertBackupNameToId "$1"; else BACK_ID="$1"; fi
	#curldeleteauth $TOKEN "$AUTH_URL_CBACKUPS/$BACK_ID" | jq '.'
	BACKUP=$(curlpostauth $TOKEN "" "$AUTH_URL_CBACKUPS/$BACK_ID") || exit 3
	TASKID=$(echo "$BACKUP" | jq '.job_id' | cut -d':' -f 2 | tr -d '" ')
	if test -z "$TASKID" -o "$TASKID" = "null"; then echo "ERROR: $BACKUP" 2>&1; exit 2; fi
	WaitForTask $TASKID
}

deleteBackup()
{
	local SNAP_ID SNAP_NAME
	# TODO: Should we delete an associated snapshot as well that might have been
	# created via the cloudbackups OTC service API along with the backup?
	if ! is_uuid "$1"; then convertBackupNameToId "$1"; else BACK_ID="$1"; fi
	SNAP_ID=$(curlgetauth $TOKEN "$AUTH_URL_BACKS/$BACK_ID" | jq '.backup.container' | tr -d '"'; return ${PIPESTATUS[0]})
	RC=$?
	if test -n "$SNAP_ID" -a "$SNAP_ID" != "null"; then
		SNAP_NAME=$(curlgetauth $TOKEN "$AUTH_URL_SNAPS/$SNAP_ID" | jq '.snapshot.name' | tr -d '"'; return ${PIPESTATUS[0]})
		RC=$?
		if test -n "$SNAP_NAME" -a "$SNAP_NAME" != "null"; then
			if test "${SNAP_NAME:0:17}" = "autobk_snapshot_2"; then
				echo "Also deleting autogenerated container/snapshot $SNAP_ID ($SNAP_NAME)" 1>&2
				deleteSnapshot $SNAP_ID
			else
				echo "Not deleting container/snapshot $SNAP_ID ($SNAP_NAME), consider manual deletion" 1>&2
			fi
		fi
	fi
	curldeleteauth $TOKEN "$AUTH_URL_BACKS/$BACK_ID" | jq '.'
	return ${PIPESTATUS[0]}
}

createBackup()
{
	local BACKUP
	if test "$1" == "--name"; then NAME="$2"; shift; shift; fi
	if test -z "$1"; then echo "ERROR: Need to specify volumeid to be backed up" 1>&2; exit 2; fi
	if test -z "$NAME"; then NAME="Backup-$1"; fi

	if ! is_uuid "$1"; then VOL_ID=`curlgetauth $TOKEN "$AUTH_URL_VOLS?name=$1" | jq '.volumes[] | select(.name == "'$1'") | .id' | tr -d '" ,'`; else VOL_ID="$1"; fi
	if ! is_uuid "$VOL_ID"; then echo "WARN: No such volume $1" 1>&2; fi
	local REQ="{ \"backup\": { \"volume_id\": \"$VOL_ID\", \"name\": \"$NAME\" } }"
	if test -n "$DESCRIPTION"; then REQ="${REQ%\} \}}, \"description\": \"$DESCRIPTION\" } }"; fi
	BACKUP=$(curlpostauth $TOKEN "$REQ" "$AUTH_URL_CBACKUPS")
	RC=$?
	TASKID=$(echo "$BACKUP" | jq '.job_id' | cut -d':' -f 2 | tr -d '" ')
	if test -z "$TASKID" -o "$TASKID" = "null"; then echo "ERROR: $BACKUP" 2>&1; exit 2; fi
	echo "Not waiting for backup, use otc task show $TASKID to monitor (but wait for backup_id)"
	WaitForTaskFieldOpt $TASKID '.entities.backup_id'
}

restoreBackup()
{
	if ! is_uuid "$1"; then convertBackupNameToId "$1"; else BACK_ID="$1"; fi
	if test -z "$2"; then echo "ERROR: Need to specify backupid and volumeid" 1>&2; exit 2; fi
	VOL_ID="$2"
	if ! is_uuid "$2"; then VOL_ID=`curlgetauth $TOKEN "$AUTH_URL_VOLS?name=$2" | jq '.volumes[] | select(.name == "'$2'") | .id' | tr -d '" ,'`; fi
	if ! is_uuid "$VOL_ID"; then echo "WARN: No such volume $2" 1>&2; fi
	local REQ="{ \"restore\": { \"volume_id\": \"$VOL_ID\" } }"
	curlpostauth $TOKEN "$REQ" "$AUTH_URL_CBACKUPS/$BACK_ID/restore" | jq '.'
	#echo
	return ${PIPESTATUS[0]}
}

getSUBNETList()
{
	FILTER=$(concatarr "&" "$@")
	FILTER="${FILTER// /%20}"
	#curlgetauth $TOKEN "$AUTH_URL_SUBNETS?limit=800" | jq '.[]'
	#setlimit 800
	setlimit; setapilimit 360 20 subnets
   if test -z "$PARAMSTRING" -a -n "$FILTER"; then FILTER="?${FILTER:1}"; fi
   # V1 Huawei API - filtering not working
	curlgetauth_pag $TOKEN  "$AUTH_URL_SUBNETS$PARAMSTRING$FILTER" | jq -r '.subnets[] | .id+"   "+.name+"   "+.status+"   "+.cidr+"   "+.vpc_id+"   "+.availability_zone' | tr -d '"'
	return ${PIPESTATUS[0]}
}

getSUBNETDetail()
{
	if ! is_uuid "$1"; then convertSUBNETNameToId "$1" "$VPCID"; else SUBNETID="$1"; fi
	curlgetauth $TOKEN "$AUTH_URL_SUBNETS/$SUBNETID" | jq '.[]'
	return ${PIPESTATUS[0]}
	# FIXME: Add tag display?
}

SUBNETDelete()
{
	if test -z "$VPCID"; then echo "ERROR: Need to specify --vpc-name/-id" 1>&2; exit 2; fi
	if ! is_uuid "$1"; then convertSUBNETNameToId "$1" "$VPCID"; else SUBNETID="$1"; fi
	curldeleteauth $TOKEN "$AUTH_URL_VPCS/$VPCID/subnets/$SUBNETID"
	local RC=$?
	echo
	return $RC
}

getRDSInstanceList()
{
	#setlimit 500
	curlgetauth $TOKEN "${AUTH_URL_RDS_DOMAIN}/instances" | jq -r  '.instances[] | {id: .id, name: .name, type: .type} | .id + "   " + .name + " " + .type'
	return ${PIPESTATUS[0]}
}

getRDSAllInstanceDetailsImpl()
{
	#setlimit 500
	curlgetauth $TOKEN "${AUTH_URL_RDS_DOMAIN}/instances" | jq -r '.instances[]'
	return ${PIPESTATUS[0]}
}

getRDSInstanceDetailsImpl()
{
	local instanceid
	for instanceid in $*; do
		local URI="${AUTH_URL_RDS_DOMAIN}/instances/${instanceid}"
		#echo "URI: $URI"
		curlgetauth $TOKEN "$URI" | jq -r '.instance'
	done
	return ${PIPESTATUS[0]}
}

getRDSInstanceDetails()
{
	[ $# -eq 0 ] && getRDSAllInstanceDetailsImpl
	[ $# -ne 0 ] && getRDSInstanceDetailsImpl "$@"
}

getRDSDatastoreDetails()
{
	local datastore_name
	for datastore_name in $*; do
		local URI="${AUTH_URL_RDS_DOMAIN}/datastores/${datastore_name}/versions"
		#echo "URI: $URI"
		curlgetauth $TOKEN "$URI" | jq -r '.dataStores[]'
	done
	return ${PIPESTATUS[0]}
}

getRDSDatastoreParameters()
{
	local datastore_version_id
	for datastore_version_id in $*; do
		local URI="${AUTH_URL_RDS_PROJECT}/datastores/versions/${datastore_version_id}/parameters"
		#echo "URI: $URI"
		curlgetauth $TOKEN "$URI" | jq -r '.[]'
	done
	return ${PIPESTATUS[0]}
}

getRDSDatastoreParameterImpl()
{
	local datastore_version_id=$1
	local parameter_name=$2
	local URI="${AUTH_URL_RDS_PROJECT}/datastores/versions/${datastore_version_id}/parameters/${parameter_name}"
	#echo "URI: $URI"
	curlgetauth $TOKEN "$URI" | jq -r '.'
	return ${PIPESTATUS[0]}
}

getRDSDatastoreParameter()
{
	[ $# -eq 2 ] && getRDSDatastoreParameterImpl "$@"
	[ $# -eq 0 ] && echo "ERROR: Please specify the RDS datastore id and parameter name" 1>&2
}

getRDSAPIVersionList()
{
	curlgetauth $TOKEN "${AUTH_URL_RDS}/" | \
		jq -r  '.versions[] | {id: .id, status: .status, updated: .updated} | .id+" "+.status+" "+.updated'
	return ${PIPESTATUS[0]}
}

getRDSAPIDetails()
{
	local api_id
	for api_id in $*; do
		curlgetauth $TOKEN "${AUTH_URL_RDS}/${api_id}" | jq .versions[]
	done
	return ${PIPESTATUS[0]}
}

getRDSFlavorList()
{
	local dbid=$1;   shift
	local region=$1; shift
	[ -z "$region" ] && region=$OS_PROJECT_NAME # default to env
	local URI="${AUTH_URL_RDS_DOMAIN}/flavors?dbId=${dbid}&region=${region}"
	#echo "URI: $URI"
	curlgetauth $TOKEN "$URI" | jq -r '.'
	#\ jq -r  '.instances[] | {id: .id, name: .name, type: .type} | .id + "   " + .name + " " + .type'
	return ${PIPESTATUS[0]}
}

getRDSFlavorDetails()
{
	for flavorid in $*; do
		local URI="${AUTH_URL_RDS_DOMAIN}/flavors/${flavorid}"
		#echo "URI: $URI"
		curlgetauth $TOKEN "$URI" | jq -r '.flavor'
	done
	return ${PIPESTATUS[0]}
}

createRDSInstanceImpl()
{
	# Parameter $* as descibed in
	# API Reference Issue 01 2016-06-30,
	# 4.7 Creating an Instance
	local URI="${AUTH_URL_RDS_DOMAIN}/instances"
	#echo "Parameter: $*"
	#echo "URI: $URI"
	curlpostauth $TOKEN "$*" "$URI" | jq '.'
	return ${PIPESTATUS[0]}
}

createRDSInstance()
{
	local rds_parameters="",zwerg;
	if [ $# -eq 0 ]; then
		# no parameter file given, read from stdin
		while read zwerg; do
			rds_parameters.="$zwerg"
		done
	else
		rds_parameters=`cat $1`
	fi
	createRDSInstanceImpl "$rds_parameters"
}

deleteRDSInstanceImpl()
{
	local instanceid=$1
	local numberOfManualBackupsToKeep=$2
	local URI="${AUTH_URL_RDS_DOMAIN}/instances/${instanceid}"
	#local URI="${AUTH_URL_RDS_PROJECT}/instances/${instanceid}"
	echo "#Note: Try deleting instance $instanceid" 1>&2
	#echo "URI: $URI"
	#echo "TOKEN: $TOKEN"
	curldeleteauthwithjsonparameter \
		$TOKEN \
		"{ \"keepLastManualBackup\":\"${numberOfManualBackupsToKeep}\" }" \
		"$URI"
}

deleteRDSInstance()
{
	[ $# -eq 2 ] && deleteRDSInstanceImpl "$@"
	[ $# -ne 2 ] && echo "ERROR: Please specify RDS instance id to delete and number of backups to keep" 1>&2
}

getRDSInstanceBackupPolicy()
{
	local instanceid
	for instanceid in $*; do
		local URI="${AUTH_URL_RDS_DOMAIN}/instances/${instanceid}/backups/policy"
		#echo "URI: $URI"
		curlgetauth $TOKEN "$URI" | jq -r '.[]'
	done
	return ${PIPESTATUS[0]}
}

getRDSSnapshots()
{
	local URI="${AUTH_URL_RDS_PROJECT}/backups"
	#echo "URI: $URI"
	curlgetauth $TOKEN "$URI" | jq -r '.'
	return ${PIPESTATUS[0]}
}

printHelpQueryRDSErrorLogs()
{
	echo 1>&2 "Parameters are: instanceId, startDate, endDate, page, entries"
	echo 1>&2 "Where:"
	echo 1>&2 "'instanceId' are the id of the database instance"
	echo 1>&2 "'startDate' and 'endDate' are of format like: 2016-08-29+06:35"
	echo 1>&2 "'page' is the page number, starting from 1"
	echo 1>&2 "'entries' the number of log lines per page, valid numbers are 1 to 100"
}

getRDSErrorLogsPrepareRequestParameters()
{
	if [ $# -eq 5 ]; then
		local startDate=${2/:/%3A} # : => %3A
		local endDate=${3/:/%3A} # : => %3A
		echo "$1 $startDate $endDate $4 $5"
		return 0
	fi
	echo "ERROR: 5 parameters are expected" 1>&2
	printHelpQueryRDSErrorLogs
	echo ""
	return 1
}

getRDSErrorLogsImpl()
{
	local instanceId=$1
	local startDate=$2
	local endDate=$3
	local curPage=$4
	local perPage=$5
	local URI="${AUTH_URL_RDS_PROJECT}/instances/${instanceId}/errorlog"
	URI+="?startDate=${startDate}"
	URI+="&endDate=${endDate}"
	URI+="&curPage=${curPage}"
	URI+="&perPage=${perPage}"
	#echo "URI: $URI"
	curlgetauth $TOKEN "$URI" | jq -r '.errorLogList[]| "\(.datetime) \(.content)"'
	return ${PIPESTATUS[0]}
}

getRDSErrorLogs()
{
	local parameters=$(getRDSErrorLogsPrepareRequestParameters $*)
	[ -n "$parameters" ] && getRDSErrorLogsImpl $parameters
}

getRDSSlowStatementLogsImpl()
{
	local instanceId=$1
	local sftype=$(echo "$2" | tr '[:lower:]' '[:upper:]')
	local top=$3
	local URI="${AUTH_URL_RDS_PROJECT}/instances/${instanceId}/slowlog"
	URI+="?sftype=${sftype}"
	URI+="&top=${top}"
	#echo "URI: $URI"
	curlgetauth $TOKEN "$URI" | jq -r '.slowLogList[]'
	return ${PIPESTATUS[0]}
}

getRDSSlowStatementLogs()
{
	[ $# -eq 3 ] && getRDSSlowStatementLogsImpl "$@"
	[ $# -ne 3 ] && echo "ERROR: Please specify instance id, statement type and number of logs to show" 1>&2
}

createRDSSnapshotImpl()
{
	local instanceId=$1
	local name=$2
	local description=$3
	local URI="${AUTH_URL_RDS_PROJECT}/backups"
	local REQ=""
	REQ+="{"
	REQ+='	"backup": {'
	REQ+='		"name":        "'${name}'",'
	REQ+='		"instance":    "'${instanceId}'",'
	REQ+='		"description": "'${description}'"'
	REQ+="	}"
	REQ+="}"
	#echo "URI: $URI"
	#echo "REQ: $REQ"
	curlpostauth $TOKEN "$REQ" "$URI" | jq -r '.'
	return ${PIPESTATUS[0]}
}

createRDSSnapshot()
{
	[ $# -eq 3 ] && createRDSSnapshotImpl "$@"
	[ $# -ne 3 ] && echo "ERROR: Please specify instance id, name and a description of the snapshot" 1>&2
}

deleteRDSSnapshot()
{
	if [ $# -eq 1 ]; then
		local backupId=$1
		local URI="${AUTH_URL_RDS_PROJECT}/backups/${backupId}"
		curldeleteauth_language $TOKEN $URI | jq .
		RC=${PIPESTATUS[0]}
	else
		echo "ERROR: Please specify snapshot/backup id to delete" 1>&2
	fi
	return $RC
}

listDomains()
{
	setlimit 100
	#setlimit; setapilimit 500 100 zones
	#curlgetauth $TOKEN $AUTH_URL_DNS$PARAMSTRING | jq -r '.'
	curlgetauth $TOKEN $AUTH_URL_DNS$PARAMSTRING | jq -r 'def str(s): s|tostring; .zones[] | .id+"   "+.name+"   "+.status+"   "+.zone_type+"   "+str(.ttl)+"   "+str(.record_num)+"   "+.description'
	RC=${PIPESTATUS[0]}
	curlgetauth $TOKEN "$AUTH_URL_DNS$PARAMSTRING&type=private" | jq -r 'def str(s): s|tostring; .zones[] | .id+"   "+.name+"   "+.status+"   "+.zone_type+"   "+str(.ttl)+"   "+str(.record_num)+"   "+.description'
	return ${PIPESTATUS[0]}
}

# Params: NAME [DESC [TYPE [EMAIL [TTL]]]]
createDomain()
{
	if test -z "$1"; then echo "Must specify domain name" 1>&2; dnsHelp; exit 1; fi
	if test "${1: -1:1}" != "."; then
		echo "WARN: Zone/Domain name should end in '.'" 1>&2
	fi
	local REQ="{ \"name\": \"$1\""; shift
	if test -n "$1"; then REQ="$REQ, \"description\": \"$1\""; shift; fi
	if test -n "$1"; then REQ="$REQ, \"zone_type\": \"$1\""; PP="$1"; shift; fi
	if test -n "$1"; then REQ="$REQ, \"email\": \"$1\""; shift; fi
	if test -n "$1"; then REQ="$REQ, \"ttl\": $1"; shift; fi
	# FIXME: Add tagging support
	if test "$PP" == "private"; then
		if test -z "$VPCID" -a -z "$VPCNAME"; then
			if test "$1" == "--vpc-id"; then VPCID="$2"; shift; shift
			elif test "$1" == "--vpc-name"; then VPCNAME="$2"; shift; shift
			else
				echo "Need to specify VPC (--vpc-id or --vpc-name) for private domain" 1>&2;
				exit 1;
			fi
		fi
		if test -z "$VPCID"; then convertVPCNameToId $VPCNAME; fi
		REQ="$REQ, \"router\": { \"router_id\": \"$VPCID\", \"router_region\": \"$OS_REGION_NAME\" }"
	fi
	REQ="$REQ }"
	curlpostauth $TOKEN "$REQ" $AUTH_URL_DNS | jq .
	return ${PIPESTATUS[0]}
}

domainNameID()
{
	if is_id "$1"; then echo "$1"; return; fi
	local NAME=$(uriencode $1)
	ID=$(curlgetauth $TOKEN "${AUTH_URL_DNS}?name=$NAME" | jq '.zones[] | select(.name == "$1") | .id' | tr -d '"')
	if is_id "$ID"; then echo "$ID"; return; fi
	ID=$(curlgetauth $TOKEN "${AUTH_URL_DNS}?type=private&name=$NAME" | jq '.zones[] | select(.name == "$1") | .id' | tr -d '"')
	if is_id "$ID"; then echo "$ID"; return; fi
	ID=$(curlgetauth $TOKEN "${AUTH_URL_DNS}?name=$NAME" | jq '.zones[] | .id' | tail -n1 | tr -d '"')
	if is_id "$ID"; then echo "$ID"; return; fi
	ID=$(curlgetauth $TOKEN "${AUTH_URL_DNS}?type=private&name=$NAME" | jq '.zones[] | .id' | tail -n1 | tr -d '"')
	if is_id "$ID"; then echo "$ID"; return; fi
	echo "No such zone $1" 1>&2
	exit 2
}


showDomain()
{
	ID=$(domainNameID $1) || exit
	curlgetauth $TOKEN $AUTH_URL_DNS/$ID | jq .
	return ${PIPESTATUS[0]}
}

deleteDomain()
{
	ID=$(domainNameID $1) || exit
	curldeleteauth $TOKEN $AUTH_URL_DNS/$ID | jq .
	return ${PIPESTATUS[0]}
}

# Params: ZONEID NAME TYPE TTL VAL[,VAL] [DESC]
addRecord()
{
	ID=$(domainNameID $1) || exit
	if test -z "$5"; then
		echo "ERROR: Need to provide more params" 1>&2
		exit 1
	fi
	case "$3" in
		A|AAAA|MX|PTR|CNAME|NS|TXT)
			;;
		*)
			echo "WARN: Unknown record type \"$3\"" 1>&2
			;;
	esac
	if test "${2: -1:1}" != "."; then
		echo "WARN: Name should end in '.'" 1>&2
	fi
	local REQ="{ \"name\": \"$2\", \"type\": \"$3\", \"ttl\": $4"
	if test -n "$6"; then REQ="$REQ, \"description\": \"$6\""; fi
	local OLDIFS="$IFS"
	local VALS=""
	IFS=","
	for val in $5; do VALS="$VALS \"$val\","; done
	IFS="$OLDIFS"
	REQ="$REQ, \"records\": [ ${VALS%,} ] }"
	curlpostauth $TOKEN "$REQ" $AUTH_URL_DNS/$ID/recordsets | jq '.'
	return ${PIPESTATUS[0]}
}

showRecord()
{
	ID=$(domainNameID $1) || exit
	curlgetauth $TOKEN $AUTH_URL_DNS/$ID/recordsets/$2 | jq '.'
	return ${PIPESTATUS[0]}
}

listRecords()
{
    PAGESIZE=100
	if test -z "$1"; then
        URL="${AUTH_URL_DNS%zones}recordsets?limit=$PAGESIZE"
	else
		ID=$(domainNameID $1) || exit
        URL="$AUTH_URL_DNS/$ID/recordsets?limit=$PAGESIZE"
        echo $URL
        fi
        while : ; do
        next_link=$(curlgetauth $TOKEN "$URL" | tee -a /tmp/dns.$$.json | jq -r '.links.next')
                [ -z "$next_link" ] && break
        [ $next_link == "null" ] && break
                URL="$next_link"
    done
    cat /tmp/dns.$$.json | jq -r 'def str(s): s|tostring; .recordsets[] | .id+"   "+.name+"   "+.status+"   "+.type+"   "+str(.ttl)+"   "+str(.records)' | arraytostr
          unlink /tmp/dns.$$.json
        return ${PIPESTATUS[0]}    
}
deleteRecord()
{
	curldeleteauth $TOKEN "$AUTH_URL_DNS/$1/recordsets/$2" | jq .
	return ${PIPESTATUS[0]}
}

associateDomain()
{
	ID=$(domainNameID $1) || exit
	if ! is_uuid $2; then convertVPCNameToId "$2"; else VPCID=$2; fi
	local REQ="{ \"router\": { \"router_id\": \"$VPCID\", \"router_region\": \"$OS_REGION_NAME\" } }"
	curlpostauth $TOKEN "$REQ" "$AUTH_URL_DNS/$ID/associaterouter" | jq '.'
}

dissociateDomain()
{
	ID=$(domainNameID $1) || exit
	if ! is_uuid $2; then convertVPCNameToId "$2"; else VPCID=$2; fi
	local REQ="{ \"router\": { \"router_id\": \"$VPCID\", \"router_region\": \"$OS_REGION_NAME\" } }"
	curlpostauth $TOKEN "$REQ" "$AUTH_URL_DNS/$ID/disassociaterouter" | jq '.'
}


# concatenate array using $1 as concatenation token
concatarr()
{
	local ans=""
	local delim="$1"
	shift
	for str in "$@"; do
		ans="$ans$delim$str"
	done
	echo "$ans"
}

getIMAGEList()
{
	local IMAGE_FILTER=$(concatarr "&" "$@")
	IMAGE_FILTER="${IMAGE_FILTER// /%20}"
	#setlimit 800
	setlimit; setapilimit 1600 100 images
   if test -z "$PARAMSTRING" -a -n "$IMAGE_FILTER"; then IMAGE_FILTER="?${IMAGE_FILTER:1}"; fi
	curlgetauth_pag $TOKEN "$AUTH_URL_IMAGES$PARAMSTRING$IMAGE_FILTER"| jq 'def str(v): v|tostring; .images[] | .id +"   "+.name+"   "+.status+"   "+str(.min_disk)+"   "+.visibility+"   "+.__platform+"   "+.virtual_env_type' | tr -d '"'
	return ${PIPESTATUS[0]}
}

getIMAGEDetail()
{
	if ! is_uuid "$1"; then convertIMAGENameToId "$1"; else IMAGE_ID="$1"; fi
	#curlgetauth $TOKEN "$AUTH_URL_IMAGES?limit=800"| jq '.images[] | select(.id == "'$IMAGE_ID'")'
	curlgetauth $TOKEN "$AUTH_URL_IMAGES/$IMAGE_ID" | jq '.'
	return ${PIPESTATUS[0]}
}

registerIMAGE()
{
	if test -z "$1"; then echo "ERROR: Need to specify NAME" 1>&2; exit 2; fi
	if test -z "$2"; then echo "ERROR: Need to specify OBSBucket" 1>&2; exit 2; fi
	if test -z "$MINDISK"; then echo "ERROR: Need to specify --min-disk" 1>&2; exit 2; fi
	if test -z "$MINRAM"; then MINRAM=1024; fi
	if test -z "$DISKFORMAT"; then DISKFORMAT="${2##*.}"; fi
	if test -z "$DISKFORMAT" -o "$DISKFORMAT" = "zvhd"; then DISKFORMAT="vhd"; fi
	local OSVJSON=""
	if test -n "$OSVERSION"; then OSVJSON="\"os_version\": \"$OSVERSION\","; fi
	local OLDIFS="$IFS"; IFS=","
	for prop in $PROPS; do
		local val="${prop##*=}"
		case $val in
			[0-9]*|false|False|true|True)
				pstr=`echo "$prop" | sed 's/^_*\([^=]*\)=\(.*\)$/"\1": \2/'`
				;;
			*)
				pstr=`echo "$prop" | sed 's/^_*\([^=]*\)=\(.*\)$/"\1": "\2"/'`
				;;
		esac
		OSVJSON="$OSVJSON $pstr,"
	done < <( echo "$PROPS")
	IFS="$OLDIFS"
	local REQ="{ $OSVJSON  \"min_disk\": $MINDISK, \"min_ram\": $MINRAM,
		\"disk_format\": \"$DISKFORMAT\", \"name\": \"$1\", \"image_url\": \"$2\" }"
	IMGTASKID=`curlpostauth $TOKEN "$REQ" "$AUTH_URL_IMAGESV2/action" | jq '.job_id' | cut -d':' -f 2 | tr -d '" '; return ${PIPESTATUS[0]}`
	WaitForTaskFieldOpt $IMGTASKID '.entities.image_id' 5 150
}

createIMAGE()
{
	local RESP
	if test -z "$DISKFORMAT"; then DISKFORMAT="vhd"; fi
	if test -z "$MINDISK" -a -z "$INSTANCE_ID"; then echo "ERROR: Need to specify --min-disk OR --instance-id" 1>&2; exit 2; fi
	if test -z "$MINRAM"; then MINRAM=1024; fi
	if test -n "$1"; then IMAGENAME="$1"; fi
	if test -z "$IMAGENAME"; then echo "ERROR: Need to specify NAME with --image-name" 1>&2; exit 2; fi
	local OSVJSON=""
	if test -n "$OSVERSION"; then OSVJSON="\"__os_version\": \"$OSVERSION\","; fi
	local OLDIFS="$IFS"; IFS=","
	for prop in $PROPS; do
		local val="${prop##*=}"
		case $val in
			[0-9]*|false|False|true|True)
				pstr=`echo "$prop" | sed 's/^\([^=]*\)=\(.*\)$/"\1": \2/'`
				;;
			*)
				pstr=`echo "$prop" | sed 's/^\([^=]*\)=\(.*\)$/"\1": "\2"/'`
				;;
		esac
		OSVJSON="$OSVJSON $pstr,"
	done < <( echo "$PROPS")
	IFS="$OLDIFS"
	if test -z "$INSTANCE_ID"; then
		# Create fresh image
		local REQ="{ $OSVJSON  \"container_format\": \"bare\",
			\"disk_format\": \"$DISKFORMAT\", \"min_disk\": $MINDISK,
			\"min_ram\": $MINRAM, \"name\": \"$IMAGENAME\",
			\"visibility\": \"private\", \"protected\": false }"
		if test -n "$TYPE"; then REQ="${REQ%\}}, \"type\": \"$TYPE\" }"; fi
		if test -n "$DESCRIPTION"; then REQ="${REQ%\}}, \"description\": \"$DESCRIPTION\" }"; fi
		curlpostauth $TOKEN "$REQ" "$AUTH_URL_IMAGES" | jq '.' #'.[]'
		return ${PIPESTATUS[0]}
	else
		# Create VM snapshot image
		if ! is_uuid "$INSTANCE_ID"; then convertECSNameToId "$INSTANCE_ID"; INSTANCE_ID=$ECS_ID; fi
		local REQ="{ \"name\": \"$IMAGENAME\", \"instance_id\": \"$INSTANCE_ID\" }"
		if test -n "$TYPE"; then REQ="${REQ%\}}, \"type\": \"$TYPE\" }"; fi
		if test -n "$DESCRIPTION"; then REQ="${REQ%\}}, \"description\": \"$DESCRIPTION\" }"; fi
		RESP=$(curlpostauth $TOKEN "$REQ" "$AUTH_URL_IMAGESV2/action" | jq '.'; return ${PIPESTATUS[0]})
		RC=$?
		echo "$RESP"
		IMGTASKID=`echo "$RESP" | jq '.job_id' | cut -d':' -f 2 | tr -d '" '; return ${PIPESTATUS[0]}`
		IMGID=`WaitForTaskFieldOpt $IMGTASKID '.entities.image_id' 5 120 | tail -n1`
		if is_uuid "$IMGID"; then getIMAGEDetail $IMGID; fi
		return $RC
	fi
}


copyIMAGE()
{
	if test -z "$1"; then echo "ERROR: Need to specify source IMAGE" 1>&2; exit 2; fi
	if test -z "$2"; then echo "ERROR: Need to specify a destination IMAGE NAME" 1>&2; exit 2; fi
	# create image copy request
	if ! is_uuid "$1"; then convertIMAGENameToId "$1"; else IMAGE_ID="$1"; fi
		
	local REQ="{ \"name\": \"$2\" }"
	if test -n "$DESCRIPTION"; then REQ="${REQ%\}}, \"description\": \"$DESCRIPTION\" }"; fi
	if test -n "$CMKID"; then REQ="${REQ%\}}, \"cmk_id\": \"$CMKID\" }"; fi
	RESP=$(curlpostauth $TOKEN "$REQ" "$AUTH_URL_IMAGESV1/$IMAGE_ID/copy" | jq '.'; return ${PIPESTATUS[0]})
	RC=$?
	echo "$RESP"
	IMGTASKID=`echo "$RESP" | jq '.job_id' | cut -d':' -f 2 | tr -d '" '; return ${PIPESTATUS[0]}`
	IMGID=`WaitForTaskFieldOpt $IMGTASKID '.entities.image_id' 5 120 | tail -n1`
	if is_uuid "$IMGID"; then getIMAGEDetail $IMGID; fi
	return $RC
    
}

deleteIMAGE()
{
	if ! is_uuid "$1"; then convertIMAGENameToId "$1"; else IMAGE_ID="$1"; fi
	curldeleteauth $TOKEN "$AUTH_URL_IMAGES/$IMAGE_ID"
	#return $?
}

uploadIMAGEobj()
{
	local ANS
	# The image upload via s3 bucket has been moved to v1 endpoint
	if ! is_uuid "$1"; then convertIMAGENameToId "$1"; else IMAGE_ID="$1"; fi
	ANS=$(curlputauth $TOKEN "{ \"image_url\":\"$2\" }" "$AUTH_URL_IMAGESV1/$IMAGE_ID/upload")
	RC=$?
	# Fall back to intermediate solution which abused the v2 OpenStack API
	case "$ANS" in
	*"Api does not exist"*)
		curlputauth $TOKEN "{ \"image_url\":\"$2\" }" "$AUTH_URL_IMAGES/$IMAGE_ID/file"
		RC=$?
		;;
	*)
		echo "$ANS"
		;;
	esac
	return $RC
}

uploadIMAGEfile()
{
	local sz=$(stat -c "%s" "$2")
	if ! is_uuid "$1"; then convertIMAGENameToId "$1"; else IMAGE_ID="$1"; fi
	echo "INFO: Uploading $sz bytes from $2 to image $IMAGE_ID ..." 1>&2
	curlputauthbinfile $TOKEN "$2" "$AUTH_URL_IMAGES/$IMAGE_ID/file"
	#return $?
}

IMGJOBID=""
downloadIMAGE()
{
	local IMSANS
	if ! is_uuid "$1"; then convertIMAGENameToId "$1"; else IMAGE_ID="$1"; fi
	if test -z "$DISKFORMAT"; then DISKFORMAT="${2##*.}"; fi
	IMSANS=`curlpostauth $TOKEN "{ \"bucket_url\": \"$2\", \"file_format\": \"$DISKFORMAT\" }" "$AUTH_URL_IMAGESV1/$IMAGE_ID/file"`
	RC=$?
	echo "$IMSANS"
	IMGJOBID=`echo "$IMSANS" | jq '.job_id' | cut -d':' -f 2 | tr -d '" '`
	return $RC
}

updateIMAGE()
{
	# FIXME: This only updates one single value at a time, could be optimized a lot
	local OLDIFS="$IFS"; IFS=","
	if ! is_uuid "$1"; then convertIMAGENameToId "$1"; else IMAGE_ID="$1"; fi
	for prop in $PROPS; do
		curladdorreplace $TOKEN "$AUTH_URL_IMAGES/$IMAGE_ID" "${prop%%=*}" "${prop#*=}" "application/openstack-images-v2.1-json-patch"
	done
	IFS="$OLDIFS"
	# NOW handle min_disk, min_ram, name (if any change)
	if test -n "$MINDISK"; then
		curladdorreplace $TOKEN "$AUTH_URL_IMAGES/$IMAGE_ID" "min_disk" "$MINDISK" "application/openstack-images-v2.1-json-patch"
	fi
	if test -n "$MINRAM"; then
		curladdorreplace $TOKEN "$AUTH_URL_IMAGES/$IMAGE_ID" "min_ram" "$MINRAM" "application/openstack-images-v2.1-json-patch"
	fi
	if test -n "$IMAGENAME"; then
		curladdorreplace $TOKEN "$AUTH_URL_IMAGES/$IMAGE_ID" "name" "$IMAGENAME" "application/openstack-images-v2.1-json-patch"
	fi
	#return $?
}

getImgMemberList()
{
	if ! is_uuid "$1"; then convertIMAGENameToId "$1"; else IMAGE_ID="$1"; fi
	curlgetauth $TOKEN "$AUTH_URL_IMAGES/$IMAGE_ID/members" | jq -r '.members[] | .member_id+"   "+.image_id+"   "+.status'
	return ${PIPESTATUS[0]}
}

getImgMemberDetail()
{
	if ! is_uuid "$1"; then convertIMAGENameToId "$1"; else IMAGE_ID="$1"; fi
	curlgetauth $TOKEN "$AUTH_URL_IMAGES/$IMAGE_ID/members/$2" | jq -r '.'
	return ${PIPESTATUS[0]}
}

ImgMemberCreate()
{
	if ! is_uuid "$1"; then convertIMAGENameToId "$1"; else IMAGE_ID="$1"; fi
	curlpostauth $TOKEN "{ \"member\": \"$2\" }" "$AUTH_URL_IMAGES/$IMAGE_ID/members" | jq -r '.'
	return ${PIPESTATUS[0]}
}

ImgMemberDelete()
{
	if ! is_uuid "$1"; then convertIMAGENameToId "$1"; else IMAGE_ID="$1"; fi
	curldeleteauth $TOKEN "$AUTH_URL_IMAGES/$IMAGE_ID/members/$2"
	#return $?
}

ImgMemberAccept()
{
	local PRJ=${2:-$OS_PROJECT_ID}
	if ! is_uuid "$1"; then convertIMAGENameToId "$1"; else IMAGE_ID="$1"; fi
	curlputauth $TOKEN "{ \"status\": \"accepted\" }" "$AUTH_URL_IMAGES/$IMAGE_ID/members/$PRJ" | jq -r '.'
	return ${PIPESTATUS[0]}
}

ImgMemberReject()
{
	local PRJ=${2:-$OS_PROJECT_ID}
	if ! is_uuid "$1"; then convertIMAGENameToId "$1"; else IMAGE_ID="$1"; fi
	curlputauth $TOKEN "{ \"status\": \"rejected\" }" "$AUTH_URL_IMAGES/$IMAGE_ID/members/$PRJ" | jq -r '.'
	return ${PIPESTATUS[0]}
}


getFLAVORListOld()
{
	#setlimit 500
	setlimit; setapilimit 720 30 flavors
	curlgetauth_pag $TOKEN "$AUTH_URL_FLAVORS$PARAMSTRING" | jq '.[]'
	return ${PIPESTATUS[0]}
}

getFLAVORList()
{
	#curlgetauth $TOKEN "$AUTH_URL_FLAVORS?limit=500" | jq '.flavors[]'
	#setlimit 500
	setlimit; setapilimit 720 30 flavors
	curlgetauth_pag $TOKEN "$AUTH_URL_FLAVORS$PARAMSTRING" | jq '.flavors[] | "\(.id)   \(.name)   \(.vcpus)   \(.ram)   \(.os_extra_specs)"'  | sed -e 's/{*\\"}*//g' -e 's/,/ /g'| tr -d '"'
	return ${PIPESTATUS[0]}
}

length()
{
	tr -d '"' | awk '{print length}'|sort -nr|head -1
}

prettyFLAVORList()
{
	setlimit; setapilimit 720 30 flavors
   _foo=$IFS
	IFS=;DATA=$(curlgetauth_pag $TOKEN "$AUTH_URL_FLAVORS$PARAMSTRING")
	IFS=$_foo
	l_id=$(echo $DATA | jq '.flavors[] | "\(.id)"' | length)
	l_ram=$(echo $DATA | jq '.flavors[] | "\(.ram)"' | length)
	l_vcpus=$( ( echo CPU; echo $DATA | jq '.flavors[] | "\(.vcpus)"' ) | length)
	l_name=$(echo $DATA | jq '.flavors[] | "\(.name)"' | length)
	format="%${l_vcpus}s %${l_ram}s %-${l_name}s %-${l_id}s"
	dospec=""
	GREP="."
	if [ "$1" == "--spec" ]
	then
		dospec="os_extra_specs"
		[ "$2" ] && GREP="$2"
	fi
	printf "#$format %s\n" CPU Ram Name ID $dospec
	while read cpu ram name id
	do
		printf " $format\n" $cpu $ram $name $id
		[ "$dospec" ] && while read spec
			do
				printf " $format %s\n" $(let num=$(echo $format | sed -e "s/[^ ]//g" | wc -c ) ; for i in `seq 1 $num`; do echo -n "- ";done  ) $spec | grep $GREP
			done < <(echo $DATA | jq ".flavors[] | select(.id==\"$id\") | .os_extra_specs | to_entries[] | [.key, .value] | @csv" | tr , : | tr -d '"\\')
	done < <(echo $DATA | jq '.flavors[] | "\(.vcpus) \(.ram) \(.name) \(.id)"' | tr -d '"')
	return ${PIPESTATUS[0]}
}

getKEYPAIRList()
{
	#curlgetauth $TOKEN "$AUTH_URL_KEYNAMES?limit=800" | jq '.'
	#setlimit 800
	setlimit; setapilimit 1080 40 keypairs
	curlgetauth_pag $TOKEN "$AUTH_URL_KEYNAMES$PARAMSTRING" | jq '.keypairs[] | .keypair | .name+"   "+.fingerprint' | tr -d '"'
	return ${PIPESTATUS[0]}
}

getKEYPAIR()
{
	curlgetauth $TOKEN "$AUTH_URL_KEYNAMES/$1" | jq '.[]'
	return ${PIPESTATUS[0]}
}

createKEYPAIR()
{
	local PKEY=""
	if test -n "$2"; then PKEY="\"public_key\": \"$2\", "; fi
	curlpostauth $TOKEN "{ \"keypair\": { $PKEY \"name\": \"$1\" } }" "$AUTH_URL_KEYNAMES" | jq '.'
	return ${PIPESTATUS[0]}
}

deleteKEYPAIR()
{
	curldeleteauth $TOKEN "$AUTH_URL_KEYNAMES/$1"
	#return $?
}

det_StackID()
{
	local NAME ID
	if [[ "$1" = */* ]]; then STACK=$1
	elif is_uuid "$1"; then
		NAME=$(curlgetauth $TOKEN $HEAT_URL/stacks | jq -r ".stacks[] | select(.id == \"$1\") | .stack_name"; return ${PIPESTATUS[0]})
		RC=$?
		if test -z "$NAME" -o "$NAME" = "null"; then echo "ERROR: No stack found by this ID $1" 1>&2; exit 1; fi
		STACK="$NAME/$1"
	else
		ID=$(curlgetauth $TOKEN $HEAT_URL/stacks | jq -r ".stacks[] | select(.stack_name == \"$1\") | .id"; return ${PIPESTATUS[0]})
		RC=$?
		if test -z "$ID" -o "$ID" = "null"; then echo "ERROR: No stack found by this NAME $1" 1>&2; exit 1; fi
		STACK="$1/$ID"
	fi
	export STACK
	return $RC
}

# HEAT
listStacks()
{
	curlgetauth $TOKEN $HEAT_URL/stacks | jq -r '.stacks[] | .id+"   "+.stack_name+"   "+.stack_status+"   "+.description' | tr -d '"'
	return ${PIPESTATUS[0]}
}

showStack()
{
	det_StackID $1
	curlgetauth $TOKEN $HEAT_URL/stacks/$STACK | jq -r '.'
	return ${PIPESTATUS[0]}
}

listStackSnapshots()
{
	# Not supported on OTC 2.0
	det_StackID $1
	curlgetauth $TOKEN $HEAT_URL/stacks/$STACK/snapshots | jq -r '.'
	return ${PIPESTATUS[0]}
}

listStackResources()
{
	det_StackID $1
	curlgetauth $TOKEN $HEAT_URL/stacks/$STACK/resources | jq -r 'def str(s): s|tostring; .resources[] | .physical_resource_id+"   "+.resource_name+"   "+.resource_status+"   "+.resource_type+"   "+.logical_resource_id+"   "+str(.required_by)'
	return ${PIPESTATUS[0]}
}

showStackResource()
{
	det_StackID $1
	curlgetauth $TOKEN $HEAT_URL/stacks/$STACK/resources/$2 | jq -r '.'
	return ${PIPESTATUS[0]}
}

listStackEvents()
{
	det_StackID $1
	curlgetauth $TOKEN $HEAT_URL/stacks/$STACK/events | jq -r 'def str(s): s|tostring; .events[] | .id+"   "+.resource_name+"   "+.resource_status+"   "+.event_time+"   "+.logical_resource_id+"   "+.physical_resource_id'
	return ${PIPESTATUS[0]}
}

showStackTemplate()
{
	det_StackID $1
	curlgetauth $TOKEN $HEAT_URL/stacks/$STACK/template | jq -r '.'
	return ${PIPESTATUS[0]}
}

listStackResTypes()
{
	curlgetauth $TOKEN $HEAT_URL/resource_types | jq -r '.'
	return ${PIPESTATUS[0]}
}

showStackBuildInfo()
{
	curlgetauth $TOKEN $HEAT_URL/build_info | jq -r '.'
	return ${PIPESTATUS[0]}
}

listStackDeployments()
{
	# TODO: Add parsing ....
	curlgetauth $TOKEN $HEAT_URL/software_deployments | jq -r '.'
	return ${PIPESTATUS[0]}
}

showStackDeployment()
{
	curlgetauth $TOKEN $HEAT_URL/software_deployments/$1 | jq -r '.'
	return ${PIPESTATUS[0]}
}

createELB()
{
	if test -n "$3"; then BANDWIDTH=$3; fi
	if test -n "$2"; then NAME="$2"; fi
	if test -n "$1"; then
		if  is_uuid "$1" ; then VPCID=$1; else convertVPCNameToId "$1"; fi
	fi
	if [ -z "$VPCID" -a -n "$VPCNAME" ]; then convertVPCNameToId "$VPCNAME"; fi
	if test -z "$VPCID"; then echo "ERROR: Need to specify VPC" 1>&2; exit 1; fi
	local ELBTYPE='"type": "External", "bandwidth": "'$BANDWIDTH'"'
	local DEFNAME="ELB-$BANDWIDTH"
	if  test -n "$SUBNETID" -o -n "$SUBNETNAME"; then
		if [ -n "$SUBNETNAME" -a -z "$SUBNETID" ]; then
			convertSUBNETNameToId $SUBNETNAME $VPCID
		fi
		if [ -n "$SECUGROUPNAME" -a -z "$SECUGROUP" ]; then
			convertSECUGROUPNameToId "$SECUGROUPNAME"
		fi
		if test -z "$AZ"; then
			if test -n "$SUBNETAZ"; then
				#echo "WARN: Derive AZ from subnet: $SUBNETAZ" 1>&2
				AZ="$SUBNETAZ"
			else
				echo "Warning: Might need to specify AZ for internal ELB. (Can not derive from subnet.)" 1>&2
				#exit 2
			fi
		fi
		if test -n "$SUBNETAZ" -a "$SUBNETAZ" != "$AZ"; then
			echo "WARN: AZ ($AZ) does not match subnet's AZ ($SUBNETAZ)" 1>&2
		fi
		# TODO: FIXME: need to get these IDs through the API -- values are valid only for OTC Prod
		if test "$OS_CLOUD_ENV" == "otc"; then
			if [[ $AZ == 'eu-de-01' ]]; then
				AZID='bf84aba586ce4e948da0b97d9a7d62fb'
			elif [[ $AZ == 'eu-de-02' ]]; then
				AZID='bf84aba586ce4e948da0b97d9a7d62fc'
			else
				echo "WARN: No IDs known for cloud AZ $AZ" 1>&2
				AZID="$AZ"
			fi
		else
			echo "WARN: No IDs known for cloud env $OS_CLOUD_ENV" 1>&2
			AZID="$AZ"
		fi
		if test -n "$AZ"; then
			ELBTYPE='"type": "Internal", "vip_subnet_id": "'$SUBNETID'", "az": "'$AZID'"'
		else
			ELBTYPE='"type": "Internal", "vip_subnet_id": "'$SUBNETID'"'
		fi
		if test -n "$SECUGROUP"; then
			ELBTYPE="$ELBTYPE, \"security_group_id\": \"$SECUGROUP\""
		else
			echo "WARN: Need to specify --security-group-name/id" 1>&2
		fi
		DEFNAME="ELB-Int"
	fi
	if test -z "$NAME"; then
		if test -z "$INSTANCE_NAME"; then NAME="$DEFNAME"; else NAME="$INSTANCE_NAME"; fi
	fi
	export ELBJOBID
	ELBJOBID=`curlpostauth $TOKEN "{ \"name\": \"$NAME\", \"description\": \"LB\", \"vpc_id\": \"$VPCID\", $ELBTYPE, \"admin_state_up\": 1 }" "$AUTH_URL_ELB_LB" | jq '.job_id' | cut -d':' -f 2 | tr -d '" '; return ${PIPESTATUS[0]}`
	#return ${PIPESTATUS[0]}
}

getELBList()
{
	#curlgetauth $TOKEN "$AUTH_URL_ELB_LB?limit=500" | jq '.'
	#setlimit 500
	setlimit; setapilimit 500 40 loadbalancers
	curlgetauth_pag $TOKEN "$AUTH_URL_ELB_LB$PARAMSTRING" | jq '.loadbalancers[] | .id+"   "+.name+"   "+.status+"   "+.type+"   "+.vip_address+"   "+.vpc_id' | tr -d '"'
	return ${PIPESTATUS[0]}
}

getELBDetail()
{
	if ! is_id "$1"; then ID=`curlgetauth $TOKEN "$AUTH_URL_ELB_LB" | jq ".loadbalancers[] | select(.name == \"$1\") | .id" | tr -d '"'`; else ID="$1"; fi
	if test -z "$ID" -o "$ID" == "null"; then echo "ERROR: No such ELB $1" 1>&2; exit 2; fi
	curlgetauth $TOKEN "$AUTH_URL_ELB_LB/$ID" | jq '.'
	return ${PIPESTATUS[0]}
}

deleteELB()
{
	if ! is_id "$1"; then ID=`curlgetauth $TOKEN "$AUTH_URL_ELB_LB" | jq ".loadbalancers[] | select(.name == \"$1\") | .id" | tr -d '"'`; else ID="$1"; fi
	if test -z "$ID" -o "$ID" == "null"; then echo "ERROR: No such ELB $1" 1>&2; exit 2; fi
	export ELBJOBID
	ELBJOBID=`curldeleteauth $TOKEN "$AUTH_URL_ELB_LB/$ID" | jq '.job_id' | cut -d':' -f 2 | tr -d '" '; return ${PIPESTATUS[0]}`
	#return ${PIPESTATUS[0]}
}

getListenerList()
{
	#curlgetauth $TOKEN "$AUTH_URL_ELB/listeners?loadbalancer_id=$1" | jq '.[]'
	if ! is_id "$1"; then ID=`curlgetauth $TOKEN "$AUTH_URL_ELB_LB" | jq ".loadbalancers[] | select(.name == \"$1\") | .id" | tr -d '"'`; else ID="$1"; fi
	if test -z "$ID" -o "$ID" == "null"; then echo "ERROR: No such ELB $1" 1>&2; exit 2; fi
	# TODO limits?
	curlgetauth $TOKEN "$AUTH_URL_ELB/listeners?loadbalancer_id=$ID" | jq 'def str(v): v|tostring; .[] | .id+"   "+.name+"   "+.status+"   "+.protocol+":"+str(.port)+"   "+.backend_protocol+":"+str(.backend_port)+"   "+.healthcheck_id' | tr -d '"'
	return ${PIPESTATUS[0]}
}

getListenerDetail()
{
	#curlgetauth $TOKEN "$AUTH_URL_ELB/listeners?loadbalancer_id=$1" | jq '.[] | select(.id = "$2")'
	if ! is_id "$1"; then ID=`curlgetauth $TOKEN "$AUTH_URL_ELB/listeners" | jq ".[] | select(.name == \"$1\") | .id" | tr -d '"'`; else ID="$1"; fi
	if test -z "$ID" -o "$ID" == "null"; then echo "ERROR: No such listener $1" 1>&2; exit 2; fi
	curlgetauth $TOKEN "$AUTH_URL_ELB/listeners/$ID" | jq '.'
	return ${PIPESTATUS[0]}
}

deleteListener()
{
	if ! is_id "$1"; then ID=`curlgetauth $TOKEN "$AUTH_URL_ELB/listeners" | jq ".[] | select(.name == \"$1\") | .id" | tr -d '"'`; else ID="$1"; fi
	if test -z "$ID" -o "$ID" == "null"; then echo "ERROR: No such listener $1" 1>&2; exit 2; fi
	curldeleteauth $TOKEN "$AUTH_URL_ELB/listeners/$1"
	#return $?
}

# echo "otc elb addlistener <eid> <name> <proto> <port> [<alg> [<beproto> [<beport>]]]"
createListener()
{
	local ALG="$5"
	local BEPROTO="$6"
	local BEPORT=$7
	local OPTPAR STICKY CTO
	if test -z "$ALG"; then ALG="source"; fi
	if test -z "$BEPROTO"; then BEPROTO="$3"; fi
	if test -z "$BEPORT"; then BEPORT=$4; fi
	if test -n "$COOKIETIMEOUT"; then CTO=", \"cookie_timeout\": $COOKIETIMEOUT"; fi
	if test "$3" = "HTTP" -o "$3" = "HTTPS"; then
		if test "$ALG" = "roundrobin"; then STICKY=", \"session_sticky\": true, \"sticky_session_type\": \"insert\"$CTO"
		else STICKY=", \"session_sticky\": false, \"sticky_session_type\": \"insert\"$CTO"; fi
	fi
	if test -n "$ELBTIMEOUT"; then
		if test "$3" = "TCP"; then OPTPAR=", \"tcp_timeout\": $ELBTIMEOUT";
		elif test "$3" = "UDP"; then OPTPAR=", \"udp_timeout\": $ELBTIMEOUT";
		else echo "WARN: ELB ignores --timeout for $3" 1>&2; fi
	fi
	if test -n "$ELBDRAIN"; then
		if test "$3" = "TCP"; then OPTPAR="$OPTPAR, \"tcp_draining\": true, \"tcp_draining_timeout\": $ELBDRAIN";
		else echo "WARN: ELB ignore --drain for $3" 1>&2; fi
	fi
	if test -n "$SSLCERT" -a "$3" = "HTTPS"; then
		if test "$SSLCERT" != "${SSLCERT//,/}"; then
			#OPTPAR="$OPTPAR, \"certificates\": [ \"${SSLCERT//,/\",\"}\" ]"
			OPTPAR="$OPTPAR, \"certificates\": ["
			while test -n "$SSLCERT"; do
				CERT=${SSLCERT%%,*}
				SSLCERT=${SSLCERT#$CRT}
				SSLCERT=${SSLCERT#,}
				if ! is_id "$CERT"; then CERT=`curlgetauth $TOKEN "$AUTH_URL_ELB/certificate" | jq ".certificates[] | select(.name == \"CERT\") | .id" | tr -d '"'`; fi
				OPTPAR="$OPTPAR \"$CERT\","
			done
			OPTPAR="${OPTPAR%,} ]"
		else
			if ! is_id "$SSLCERT"; then SSLCERT=`curlgetauth $TOKEN "$AUTH_URL_ELB/certificate" | jq ".certificates[] | select(.name == \"$SSLCERT\") | .id" | tr -d '"'`; fi
			OPTPAR="$OPTPAR, \"certificate_id\": \"$SSLCERT\""
		fi
	fi
	if ! is_id "$1"; then ID=`curlgetauth $TOKEN "$AUTH_URL_ELB_LB" | jq ".loadbalancers[] | select(.name == \"$1\") | .id" | tr -d '"'`; else ID="$1"; fi
	if test -z "$ID" -o "$ID" == "null"; then echo "ERROR: No such ELB $1" 1>&2; exit 2; fi
	if test -n "$SSLPROTO" -a "$3" = "HTTPS"; then OPTPAR="$OPTPAR, \"ssl_protocols\": \"$SSLPROTO\""; fi
	if test -n "$SSLCIPHER" -a "$3" = "HTTPS"; then OPTPAR="$OPTPAR, \"ssl_ciphers\": \"$SSLCIPHER\""; fi
	curlpostauth $TOKEN "{ \"name\": \"$2\", \"loadbalancer_id\": \"$ID\", \"protocol\": \"$3\", \"port\": $4, \"backend_protocol\": \"$BEPROTO\", \"backend_port\": $BEPORT, \"lb_algorithm\": \"$ALG\"$OPTPAR$STICKY }" "$AUTH_URL_ELB/listeners" | jq -r '.'
	return ${PIPESTATUS[0]}
}

#echo "otc elb addcheck <lid> <proto> <port> <int> <to> <hthres> <uthres> [<uri>]"
createCheck()
{
	local HTHR="$6"
	local UTHR="$7"
	if test -z "$HTHR"; then HTHR=3; fi
	if test -z "$UTHR"; then UTHR=$HTHR; fi
	local URI="$8"
	if test "$2" = "HTTP" -o "$2" = "HTTPS" && test -z "$URI"; then URI="/"; fi
	if test -n "$URI"; then URI="\"healthcheck_uri\": \"$URI\", "; fi
	if ! is_id "$1"; then ID=`curlgetauth $TOKEN "$AUTH_URL_ELB/listeners" | jq ".[] | select(.name == \"$1\") | .id" | tr -d '"'`; else ID="$1"; fi
	if test -z "$ID" -o "$ID" == "null"; then echo "ERROR: No such listener $1" 1>&2; exit 2; fi

	curlpostauth "$TOKEN" "{ \"listener_id\": \"$ID\", \"healthcheck_protocol\": \"$2\", $URI\"healthcheck_connect_port\": $3, \"healthcheck_interval\": $4, \"healthcheck_timeout\": $5, \"healthy_threshold\": $HTHR, \"unhealthy_threshold\": $UTHR }" "$AUTH_URL_ELB/healthcheck" | jq '.[]'
	return ${PIPESTATUS[0]}
}

deleteCheck()
{
	#if ! is_id "$1"; then ID=`curlgetauth $TOKEN "$AUTH_URL_ELB/healthchecks" | jq ".[] | select(.name == \"$1\") | .id" | tr -d '"'`; else ID="$1"; fi
	#if test -z "$ID" -o "$ID" == "null"; then echo "ERROR: No such healthcheck $1" 1>&2; exit 2; fi
	curldeleteauth $TOKEN "$AUTH_URL_ELB/healthcheck/$ID"
	#return $?
}

getCheck()
{
	if ! is_id "$1"; then 
		ID=`curlgetauth $TOKEN "$AUTH_URL_ELB/listeners" | jq ".[] | select(.name == \"$1\") | .healthcheck_id" | tr -d '"'`; else ID="$1"; fi
	if test -z "$ID" -o "$ID" == "null"; then echo "ERROR: No such listener $1" 1>&2; exit 2; fi
	curlgetauth $TOKEN "$AUTH_URL_ELB/healthcheck/$ID" | jq '.'
	return ${PIPESTATUS[0]}
}

#   echo "otc elb listmember <lid>"
getMemberList()
{
	#curlgetauth $TOKEN "$AUTH_URL_ELB/listeners/$1/members" | jq '.'
	#curlgetauth $TOKEN "$AUTH_URL_ELB/listeners/$1/members" | jq 'def str(v): v|tostring; .[] | .id+"   "+.server_address+"   "+.status+"   "+.address+"   "+.health_status+"   "+str(.listeners)' | tr -d '"'
	if ! is_id "$1"; then ID=`curlgetauth $TOKEN "$AUTH_URL_ELB/listeners" | jq ".[] | select(.name == \"$1\") | .id" | tr -d '"'`; else ID="$1"; fi
	if test -z "$ID" -o "$ID" == "null"; then echo "ERROR: No such listener $1" 1>&2; exit 2; fi
	curlgetauth $TOKEN "$AUTH_URL_ELB/listeners/$ID/members" | jq 'def str(v): v|tostring; .[] | .id+"   "+.server_address+"   "+.status+"   "+.address+"   "+.health_status' | tr -d '"'
	return ${PIPESTATUS[0]}
}

getMemberDetail()
{
	if ! is_id "$1"; then ID=`curlgetauth $TOKEN "$AUTH_URL_ELB/listeners" | jq ".[] | select(.name == \"$1\") | .id" | tr -d '"'`; else ID="$1"; fi
	if test -z "$ID" -o "$ID" == "null"; then echo "ERROR: No such listener $1" 1>&2; exit 2; fi
	if ! is_id "$2"; then FILT="select(.server_address == \"$2\")"; else FILT="select(.id == \"$2\")"; fi
	curlgetauth $TOKEN "$AUTH_URL_ELB/listeners/$ID/members" | jq ".[] | $FILT"
	return ${PIPESTATUS[0]}
}

#   echo "otc elb addmember <lid> <vmid> <vmip>"
createMember()
{
	if ! is_id "$1"; then ID=`curlgetauth $TOKEN "$AUTH_URL_ELB/listeners" | jq ".[] | select(.name == \"$1\") | .id" | tr -d '"'`; else ID="$1"; fi
	if test -z "$ID" -o "$ID" == "null"; then echo "ERROR: No such listener $1" 1>&2; exit 2; fi
	VMID=$(uriencode "$2")
	if ! is_uuid "$2"; then VMID=`curlgetauth $TOKEN "$AUTH_URL_ECS?name=$VMID" | jq ".[] | select(.name == \"$2\") | .id" | tr -d '"'`; else VMID="$2"; fi
	if test -z "$VMID" -o "$VMID" == "null"; then echo "ERROR: No such VM $2" 1>&2; exit 2; fi
	curlpostauth $TOKEN "[ { \"server_id\": \"$VMID\", \"address\": \"$3\" } ]" "$AUTH_URL_ELB/listeners/$ID/members"
	#TODO JOB_ID ...
	#return $?
}

#   echo "otc elb delmember <lid> <mid> <addr>"
deleteMember()
{
	if ! is_id "$1"; then ID=`curlgetauth $TOKEN "$AUTH_URL_ELB/listeners" | jq ".[] | select(.name == \"$1\") | .id" | tr -d '"'`; else ID="$1"; fi
	if test -z "$ID" -o "$ID" == "null"; then echo "ERROR: No such listener $1" 1>&2; exit 2; fi
	if ! is_id "$2"; then MID=`curlgetauth $TOKEN "$AUTH_URL_ELB/listeners/$ID/members" | jq ".[] | select(.server_address == \"$3\") | .id" | tr -d '"'`; else MID="$2"; fi
	curlpostauth $TOKEN "{ \"removeMember\": [ { \"id\": \"$MID\", \"address\": \"$3\" } ] }" "$AUTH_URL_ELB/listeners/$ID/members/action"
	#TODO JOB_ID ...
	#return $?
}

# SSL termination
# $1 -> cert content (PEM)
# $2 -> private key (PEM)
createELBCert()
{
	local DESC NM
	local CERT="$1"; shift
	local PRIV="$1"; shift
	if test -z "$PRIV"; then echo "ELB Cert creation: Pass CERT.pem and PrivKey.pem" 1>&2; exit 2; fi
	if test ! -r "$CERT"; then echo "ELB Cert file $CERT must be readable" 1>&2; exit 2; fi
	CERT=$(cat "$CERT")
	if test ! -r "$PRIV"; then echo "ELB PrivKey file $PRIV must be readable" 1>&2; exit 2; fi
	PRIV=$(cat "$PRIV")
	if test -z "$NAME" -a -n "$1"; then NAME="$1"; if test "$NAME" == "--name"; then shift; NAME="$1"; fi; fi
	if test -z "$DOMAIN" -a -n "$2"; then DOMAIN="$2"; if test "$DOMAIN" == "--domain"; then shift; DOMAIN="$2"; fi; fi
	if test -n "$DESCRIPTION"; then DESC=", \"description\": \"$DESCRIPTION\""; fi
	if test -n "$DOMAIN"; then DESC="$DESC, \"domain\": \"$DOMAIN\""; fi
	if test -n "$KEYNAME" -a -z "$NAME"; then NAME="$KEYNAME"; fi
	if test -n "$NAME"; then NM=", \"name\": \"$NAME\""; fi
	curlpostauth $TOKEN "{ \"certificate\": \"$CERT\", \"private_key\": \"$PRIV\" $NM $DESC }"  "$AUTH_URL_ELB/certificate" | sed 's/\(-----BEGIN[A-Z ]*PRIVATE KEY-----\)[^-]*/\1\\nMIIsecretsecret/g' | jq -r '.'
	return ${PIPESTATUS[0]}
}

listELBCert()
{
	curlgetauth $TOKEN "$AUTH_URL_ELB/certificate" | jq '.certificates[] | .id+"   "+.name+"   "+.domain+"   "+.description' | tr -d '"'
	return ${PIPESTATUS[0]}
}

# API not implemented (irregularity)
showELBCert()
{
	#ID="$(uriencode $1)"
	#if ! is_id "$ID"; then ID=`curlgetauth $TOKEN "$AUTH_URL_ELB/certificate&name=$ID" | jq '.certificates[].id' | tr -d '"'`; fi
	#if ! is_id "$ID"; then ID=`curlgetauth $TOKEN "$AUTH_URL_ELB/certificate" | jq ".certificates[] | select(.name == \"$1\") | .id" | tr -d '"'`; fi
	#curlgetauth $TOKEN "$AUTH_URL_ELB/certificate/$ID" | jq -r '.'
	local FILT
	if is_id $1; then FILT="select(.id == \"$1\")"; else FILT="select(.name == \"$1\")"; fi
	curlgetauth $TOKEN "$AUTH_URL_ELB/certificate" | jq ".certificates[] | $FILT"
	return ${PIPESTATUS[0]}
}

deleteELBCert()
{
	local ID="$1"; shift
	# Std Name -> ID conversion not working with Huawei custom API :-(
	#if ! is_id "$ID"; then ID=`curlgetauth $TOKEN "$AUTH_URL_ELB/certificate&name=$ID" | jq '.certificates[].id' | tr -d '"'`; fi
	if ! is_id "$ID"; then ID=`curlgetauth $TOKEN "$AUTH_URL_ELB/certificate" | jq ".certificates[] | select(.name == \"$ID\") | .id" | tr -d '"'`; fi
	curldeleteauth $TOKEN "$AUTH_URL_ELB/certificate/$ID"
}

modifyELBCert()
{
	local ID="$1"; shift
	# Std Name -> ID conversion not working with Huawei custom API :-(
	#if ! is_id "$ID"; then ID=`curlgetauth $TOKEN "$AUTH_URL_ELB/certificate&name=$ID" | jq '.certificates[].id' | tr -d '"'`; fi
	if ! is_id "$ID"; then ID=`curlgetauth $TOKEN "$AUTH_URL_ELB/certificate" | jq ".certificates[] | select(.name == \"$ID\") | .id" | tr -d '"'`; fi
	if test -z "$ID" -o "$ID" = "null"; then echo "ERROR: No such ELB cert" 1>&2; exit 2; fi
	if test -z "$NAME" -a -n "$1"; then NAME="$1"; if test "$NAME" == "--name"; then shift; NAME="$1"; fi; fi
	if test -z "$DOMAIN" -a -n "$2"; then DOMAIN="$2"; if test "$DOMAIN" == "--domain"; then shift; DOMAIN="$2"; fi; fi
	local DESC
	if test -n "$DESCRIPTION"; then DESC="\"description\": \"$DESCRIPTION\""; fi
	if test -n "$DOMAIN"; then DESC="$DESC, \"domain\": \"$DOMAIN\""; fi
	if test -n "$NAME"; then DESC="$DESC, \"name\": \"$NAME\""; fi
	DESC="${DESC#,}"
	curlputauth	$TOKEN "{ $NM $DESC }" "$AUTH_URL_ELB/certificate/$ID" | sed 's/\(-----BEGIN[A-Z ]*PRIVATE KEY-----\)[^-]*/\1\\nMIIsecretsecret/g' | jq -r '.'
	return ${PIPESTATUS[0]}
}



# Neutron LBaaSv2 aka ULB
getULBList()
{
	setlimit; setapilimit 880 40 loadbalancers
	curlgetauth_pag $TOKEN "$NEUTRON_URL/v2.0/lbaas/loadbalancers$PARAMSTRING" | jq '.loadbalancers[] | .id+"   "+.name+"   "+.operating_status+"   "+.provider+"   "+.vip_address+"   "+.vip_subnet_id+"   "+.listeners[].id+"   "+.pools[].id' | tr -d '"'
	return ${PIPESTATUS[0]}
}

getULBDetail()
{
	local ID="$(uriencode $1)"
	if ! is_uuid "$ID"; then ID=`curlgetauth $TOKEN "$NEUTRON_URL/v2.0/lbaas/loadbalancers?name=$ID" | jq '.loadbalancers[].id' | tr -d '"'`; fi
	#setlimit; setapilimit 880 40 loadbalancers
	curlgetauth $TOKEN "$NEUTRON_URL/v2.0/lbaas/loadbalancers/$ID" | jq -r '.'
	return ${PIPESTATUS[0]}
}

getULBFullDetail()
{
	local ID="$(uriencode $1)"
	if ! is_uuid "$ID"; then ID=`curlgetauth $TOKEN "$NEUTRON_URL/v2.0/lbaas/loadbalancers?name=$ID" | jq '.loadbalancers[].id' | tr -d '"'`; fi
	#setlimit; setapilimit 880 40 loadbalancers
	curlgetauth $TOKEN "$NEUTRON_URL/v2.0/lbaas/loadbalancers/$ID/statuses" | jq -r '.'
	return ${PIPESTATUS[0]}
}

# Autoscaling
listASGroup()
{
	if test -n "$1"; then APPEND="&$1"; else APPEND=""; fi
	setlimit; setapilimit 3200 96 scaling_groups scaling_group_id
	curlgetauth_pag $TOKEN "$AUTH_URL_AS/scaling_group$PARAMSTRING$APPEND" | jq 'def str(v): v|tostring; .scaling_groups[] | .scaling_group_id+"   "+.scaling_group_name+"   "+.scaling_group_status+"   "+.scaling_configuration_id+"   "+.scaling_configuration_name+"   "+str(.current_instance_number)+"/"+str(.desire_instance_number)+"("+str(.min_instance_number)+"-"+str(.max_instance_number)+")   "+.lbListener_id+"   "+.detail' | tr -d '"'
}

showASGroup()
{
	ID=$1
	if ! is_uuid "$ID"; then ID=$(curlgetauth $TOKEN "$AUTH_URL_AS/scaling_group?scaling_group_name=$(uriencode $ID)" | jq '.scaling_groups[] | .scaling_group_id' | tr -d '"' | head -n1); fi
	if ! is_uuid "$ID"; then echo "ERROR: AS Group $1 not found" 1>&2; exit 2; fi
	curlgetauth $TOKEN "$AUTH_URL_AS/scaling_group/$ID" | jq '.'
}

listASGroupVMs()
{
	ID=$1
	if test -n "$2"; then APPEND="&$2"; else APPEND=""; fi
	if ! is_uuid "$ID"; then ID=$(curlgetauth $TOKEN "$AUTH_URL_AS/scaling_group?scaling_group_name=$(uriencode $ID)" | jq '.scaling_groups[] | .scaling_group_id' | tr -d '"' | head -n1); fi
	if ! is_uuid "$ID"; then echo "ERROR: AS Group $1 not found" 1>&2; exit 2; fi
	curlgetauth $TOKEN "$AUTH_URL_AS/scaling_group_instance/$ID/list?limit=100$APPEND" | jq 'def str(v): v|tostring; .scaling_group_instances[] | .instance_id+"   "+.instance_name+"   "+.life_cycle_state+"   "+.health_status+"   "+.scaling_configuration_name' | tr -d '"'
}


getASGroupLog()
{
	ID=$1
	if test -n "$2"; then APPEND="&$2"; else APPEND=""; fi
	if ! is_uuid "$ID"; then ID=$(curlgetauth $TOKEN "$AUTH_URL_AS/scaling_group?scaling_group_name=$(uriencode $ID)" | jq '.scaling_groups[] | .scaling_group_id' | tr -d '"' | head -n1); fi
	#setlimit; setapilimit 3200 96 'scaling_activity_log[]'
	#curlgetauth_pag $TOKEN "$AUTH_URL_AS/scaling_activity_log/$ID&limit=100$APPEND" | jq '.scaling_activity_log[]'
	curlgetauth $TOKEN "$AUTH_URL_AS/scaling_activity_log/$ID?limit=100$APPEND" | jq '.scaling_activity_log[]'
}

getASQuota()
{
	if test -z "$1"; then
		curlgetauth $TOKEN "$AUTH_URL_AS/quotas" | jq '.quotas.resources[]'
	else
		ID=$1
		if ! is_uuid "$ID"; then ID=$(curlgetauth $TOKEN "$AUTH_URL_AS/scaling_group?scaling_group_name=$(uriencode $ID)" | jq '.scaling_groups[] | .scaling_group_id' | tr -d '"' | head -n1); fi
		if ! is_uuid "$ID"; then echo "ERROR: AS Group $1 not found" 1>&2; exit 2; fi
		curlgetauth $TOKEN "$AUTH_URL_AS/quotas/$ID" | jq '.quotas.resources[]'
	fi
}

listASTags()
{
	if test -z "$1"; then echo "ERROR: Need to specify resource type" 1>&2; exit 2; fi
	if test -n "$2"; then RES="/$2"; else RES=""; fi
	curlgetauth $TOKEN "$AUTH_URL_AS/$1$RES/tags" | jq '.tags[] | .key+"="+.value' | tr -d '"'
}


listASConfig()
{
	if test -n "$1"; then APPEND="&$1"; else APPEND=""; fi
	setlimit; setapilimit 2800 96 scaling_configurations scaling_configuration_id
	curlgetauth_pag $TOKEN "$AUTH_URL_AS/scaling_configuration$PARAMSTRING$APPEND" | jq 'def str(v): v|tostring; .scaling_configurations[] | .scaling_configuration_id+"   "+.scaling_configuration_name+"   "+.instance_config.flavorRef+"   "+.instance_config.imageRef+"   "+.instance_config.key_name' | tr -d '"'
}

showASConfig()
{
	ID=$1
	if ! is_uuid "$ID"; then ID=$(curlgetauth $TOKEN "$AUTH_URL_AS/scaling_configuration?scaling_policy_name=$(uriencode $ID)" | jq '.scaling_configurations[] | .scaling_configuration_id' | tr -d '"' | head -n1); fi
	if ! is_uuid "$ID"; then echo "ERROR: AS Config $1 not found" 1>&2; exit 2; fi
	curlgetauth $TOKEN "$AUTH_URL_AS/scaling_configuration/$ID" | jq '.'
}

listASPolicy()
{
	if test -n "$2"; then APPEND="&$2"; else APPEND=""; fi
	ID=$1
	if test -z "$1"; then echo "ERROR: Need to specify AS Group" 1>&2; exit 2; fi
	if ! is_uuid "$ID"; then ID=$(curlgetauth $TOKEN "$AUTH_URL_AS/scaling_group?scaling_group_name=$(uriencode $ID)" | jq '.scaling_groups[] | .scaling_group_id' | tr -d '"' | head -n1); fi
	if ! is_uuid "$ID"; then echo "ERROR: AS Group $1 not found" 1>&2; exit 2; fi
	setlimit; setapilimit 3200 96 scaling_policies scaling_policy_id
	curlgetauth_pag $TOKEN "$AUTH_URL_AS/scaling_policy/$ID/list$PARAMSTRING$APPEND" | jq 'def str(v): v|tostring; .scaling_policies[] | .scaling_policy_id+"   "+.scaling_policy_name+"   "+.policy_status+"   "+.scaling_group_id+"   "+.scaling_policy_type+"   "+str(.cool_down_time)' | tr -d '"'
}

showASPolicy()
{
	ID=$1
	if ! is_uuid "$ID"; then ID=$(curlgetauth $TOKEN "$AUTH_URL_AS/scaling_policy?scaling_policy_name=$(uriencode $ID)" | jq '.scaling_policies[] | .scaling_policy_id' | tr -d '"' | head -n1); fi
	if ! is_uuid "$ID"; then echo "ERROR: AS Policy $1 not found" 1>&2; exit 2; fi
	curlgetauth $TOKEN "$AUTH_URL_AS/scaling_policy/$ID" | jq '.'
}

getECSlog()
{
	if ! is_uuid "$1"; then convertECSNameToId "$1"; else ECS_ID="$1"; fi
	# Assumes avg 85 chrs per line (1024/85 ~ 12)
	ln=$(($MAXGETKB*12))
	LF=$(echo -e "\n")
	curlpostauth $TOKEN "{ \"os-getConsoleOutput\": { \"length\": $ln } }" "$AUTH_URL_ECS/$ECS_ID/action" | jq '.output' | sed -e 's/^"\(.*\)"$/\1/' -e 's/\\n/\
/g'
	RC=${PIPESTATUS[0]}
	return $RC
}

getJobList()
{
	if test -z "$1"; then echo
		echo "ERROR: Need to pass job ID to getJobList" 1>&2
		exit 1
	fi

	if test -z "$2"; then echo
		echo "ERROR: Need to pass job URL to getJobList" 1>&2
		exit 1
	fi
	#curlgetauth $TOKEN "$2/$1"

	export JOBSTATUSJSON
	JOBSTATUSJSON=`curlgetauth "$TOKEN" "$2/$1"`
	RC=$?
	#echo $JOBSTATUSJSON
	export JOBSTATUS=`echo $JOBSTATUSJSON| jq '.status'|head -n 1 |cut -d':' -f 2 | tr -d '"'| tr -d ' '`

	return $RC
}

# ECS helpers
getECSJOBList()
{
	getJobList "$1" "$AUTH_URL_ECS_JOB"
	RC=$?

	export ECSJOBSTATUSJSON=$JOBSTATUSJSON
	export ECSJOBSTATUS=$JOBSTATUS

	return $RC
}

# Workspace helpers
getWorkspaceJobList()
{
	getJobList "$1" "$AUTH_URL_WORKSPACE_JOBS"
	RC=$?

	export WORKSPACEJOBSTATUSJSON=$JOBSTATUSJSON
	export WORKSPACEJOBSTATUS=$JOBSTATUS

	return $RC
}

getFileContentJSON()
{
	local INJECTFILE=$1
	if [ "$INJECTFILE" != "" ]; then
		IFS='=' read -a FILE_AR <<< "${INJECTFILE}"
		local FILENAME_NAME=${FILE_AR[1]}
		local TARGET_FILENAME=${FILE_AR[0]}
		local FILECONTENT=$( base64 -w0 "$FILENAME_NAME" )
		local FILE_TEMPLATE='{ "path": "'"$TARGET_FILENAME"'", "contents": "'"$FILECONTENT"'" }'

		export FILEJSONITEM="$FILE_TEMPLATE"
	fi
}

getPersonalizationJSON()
{
	local FILECOLLECTJSON=""
	if [ "$FILE1" != "" ]; then
		getFileContentJSON $FILE1
		FILECOLLECTIONJSON="$FILEJSONITEM"
	fi
	if [ "$FILE2" != "" ]; then
		getFileContentJSON $FILE2
		FILECOLLECTIONJSON="$FILECOLLECTIONJSON,$FILEJSONITEM"
	fi
	if [ "$FILE3" != "" ]; then
		getFileContentJSON $FILE3
		FILECOLLECTIONJSON="$FILECOLLECTIONJSON,$FILEJSONITEM"
	fi
	if [ "$FILE4" != "" ]; then
		getFileContentJSON $FILE4
		FILECOLLECTIONJSON="$FILECOLLECTIONJSON,$FILEJSONITEM"
	fi
	if [ "$FILE5" != "" ]; then
		getFileContentJSON $FILE5
		FILECOLLECTIONJSON="$FILECOLLECTIONJSON,$FILEJSONITEM"
	fi

	export PERSONALIZATION=""
	if [ "$FILECOLLECTIONJSON" != "" ]; then
		export PERSONALIZATION='
			"personality": [ '"$FILECOLLECTIONJSON"'],'
	fi
}

ECSAttachVolumeListName()
{
	local dev_vol ecs="$1" DEV_VOL="$2"
	for dev_vol in $(echo $DEV_VOL | sed 's/,/ /g'); do
		volume_az=$(getEVSDetail ${dev_vol#*:} | jq .availability_zone)
		if [ $AZ == ${volume_az//\"/} ]; then
			ECSAttachVolumeName "$ecs" $dev_vol
		else
			echo "WARN: availablity zone of ECS ${ecs} does not correspond to availabilty zone of volume ${dev_vol}, NOT ATTACHING"
		fi
	done
}

ECSAttachVolumeName()
{
	local server_name="$1" dev_vol="$2" ecsid volid
	ecsid=$(getECSList |  while read id name x; do [ "$name" = "$server_name"  -o "$id" = "$server_name"  ] && echo $id && break; done)
	volid=$(getEVSList |  while read id name x; do [ "$name" = "${dev_vol#*:}" -o "$id" = "${dev_vol#*:}" ] && echo $id && break; done)
	[ -z "$volid" ] && echo "$ERROR: volume '${dev_vol#*:}' doesn't exist" 1>&2 && return 1
	ECSAttachVolumeId  "$ecsid"  "${dev_vol%:*}:$volid"
}

# future: evs attach ecs dev:vol[,dev:vol[..]]
# today:  evs attach ecs dev:vol
ECSAttachVolumeId()
{
	local server_id="$1" dev_vol="$2" dev vol req
	IFS=: read dev vol <<< "$dev_vol"
	if test -z "$vol"; then
		echo "ERROR: wrong usage of ECSAttachVolumeId(): '$dev_vol' should be 'device:VolumeID'" 1>&2
		exit 2
	fi
	dev="/dev/${dev#/dev/}"
	req='{
            "volumeAttachment": {
                "volumeId": "'"$vol"'",
                "device": "'"$dev"'"
            }
	}'
	curlpostauth "$TOKEN" "$req" "$AUTH_URL_ECS_CLOUD/$server_id/attachvolume" | jq '.[]'
	return ${PIPESTATUS[0]}
}

ECSDetachVolumeListName()
{
	local dev_vol ecs="$1" DEV_VOL="$2"
	for dev_vol in $(echo $DEV_VOL | sed 's/,/ /g'); do
		volume_az=$(getEVSDetail ${dev_vol#*:} | jq .availability_zone)
		#if [ $AZ != ${volume_az//\"/} ]; then
		#	echo "#Warning: availablity zone of ECS ${ecs} does not correspond to availabilty zone of volume ${dev_vol}, NOT DETACHING" 1>&2
		#fi
		ECSDetachVolumeName "$ecs" $dev_vol
	done
}

ECSDetachVolumeName()
{
	local server_name="$1" dev_vol="$2" ecsid volid  ##### dev_vol could be of the form <device>:<volume> or just <volume>
	if is_uuid "$server_name"; then
		ecsid=$server_name
	else
		ecsid=$(getECSList |  while read id name x; do [ "$name" = "$server_name"  ] && echo $id && break; done)
	fi
	volid=$(getEVSList |  while read id name x; do [ "$name" = "${dev_vol#*:}" ] && echo $id && break; done)
	if test -z "$volid"; then
		echo "ERROR: could not determine volume id -- perhaps volume is not mounted or ecs name is not unique" 1>&2
		exit 2
	fi
	ECSDetachVolumeId  "$ecsid"  "${dev_vol%:*}:$volid"
}

ECSDetachVolumeId()
{
	local server_id="$1" dev_vol="$2" volume         ##### dev_vol could be of the form <device>:<volumeid> or just <volumeid>
	volume="${dev_vol#*:}"
	if test -z "$volume"; then
		echo "ERROR: wrong usage of volume detach function: volume is not set" 1>&2
		exit 2
	fi
	curldeleteauth "$TOKEN" "$AUTH_URL_ECS_CLOUD/$server_id/detachvolume/$volume" | jq '.[]'
	return ${PIPESTATUS[0]}
}

ECSAttachPort()
{
	ECS_ID=$1; shift
	if ! is_uuid "$ECS_ID"; then convertECSNameToId "$ECS_ID"; fi
	local PORTSPEC=""
	if test "$1" == "--port-id"; then PORTSPEC="\"port_id\": \"$2\""; shift; shift
	elif test "${1:0:10}" == "--port-id="; then PORTSPEC="\"port_id\": \"${1:10}\""; shift
	elif is_uuid "$1"; then PORTSPEC="\"port_id\": \"$1\""; shift
	elif test "$1" == "--net-id"; then PORTSPEC="\"net_id\": \"$2\""; shift; shift
	elif test "${1:0:9}" == "--net-id="; then PORTSPEC="\"net_id\": \"${1:9}\""; shift
	else echo "WARN: Need --net-id or --port-id, got \"$@\"" 1>&2
	fi
	if test "$1" == "--fixed-ip"; then PORTSPEC="$PORTSPEC, \"fixed_ips\": { [ \"ip_address\": \"$2\" ] }"; shift; shift
	elif test "${1:0:11}" == "--fixed-ip="; then PORTSPEC="$PORTSEPC, \"fixed_ips\": { [ \"ip_address\": \"${1:11}\" ] }"; shift
	fi
	local REQ="{ \"interfaceAttachment\": { $PORTSPEC } }"
	curlpostauth "$TOKEN" "$REQ" $AUTH_URL_ECS/$ECS_ID/os-interface | jq -r '.'
	return ${PIPESTATUS[0]}
}

ECSDetachPort()
{
	ECS_ID=$1; shift
	if ! is_uuid "$ECS_ID"; then convertECSNameToId "$ECS_ID"; fi
	local PORT=""
	if test "$1" == "--port-id"; then PORT=$2; shift; shift
	elif test "${1:0:10}" == "--port-id="; then PORT=${1:10}; shift
	elif is_uuid "$1"; then PORT=$1; shift
	else echo "WARN: Need --port-id, got \"$@\"" 1>&2
	fi
	curldeleteauth "$TOKEN" $AUTH_URL_ECS/$ECS_ID/os-interface/$PORT | jq '.'
	return ${PIPESTATUS[0]}
}

ECSprepare()
{
	if [ "$VPCNAME" != "" ]; then convertVPCNameToId "$VPCNAME"; fi
	if [ "$SUBNETNAME" != "" ]; then convertSUBNETNameToId "$SUBNETNAME" "$VPCID"; fi
	if [ -z "$IMAGE_ID" -a -n "$IMAGENAME" ]; then convertIMAGENameToId "$IMAGENAME"; fi
	SECUGROUPNAMELIST="$SECUGROUPNAME"
	if [ "$SECUGROUPNAMELIST" != "" ] && [ "$SECUGROUP" == "" ]; then
		SECUGROUP=$(IFS=,; for SECUGROUPNAME in $SECUGROUPNAMELIST; do convertSECUGROUPNameToId "$SECUGROUPNAME"; printf ",$SECUGROUP";done)
		SECUGROUP="${SECUGROUP#,}"
	fi
	if test -z "$INSTANCE_NAME"; then
		if test -n "$1"; then INSTANCE_NAME="$1"
		else INSTANCE_NAME="VM-$(date +%s)-$$"
		fi
	fi
}

ECScommonSettings()
{
	if test -n "$(echo "$INSTANCE_NAME" | sed 's/^[0-9a-zA-Z_\-]*$//')"; then
		echo "ERROR: INSTANCE_NAME may only contain letters, digits, _ and -" 1>&2
		exit 2
	fi

	if [ -n "$ROOTDISKSIZE" ]; then
		DISKSIZE=', "size": '$ROOTDISKSIZE''
	else
		unset DISKSIZE
	fi
	if test -z "$AZ"; then
		if test -n "$SUBNETAZ"; then
			AZ="$SUBNETAZ"
		else
			echo "ERROR: Need to specify AZ (or derive from subnet)" 1>&2
			exit 2
		fi
	fi
	if test -n "$SUBNETAZ" -a "$SUBNETAZ" != "$AZ"; then
		echo "WARN: AZ ($AZ) does not match subnet's AZ ($SUBNETAZ)" 1>&2
	fi

	if test -z "$NUMCOUNT"; then NUMCOUNT=1; fi

	# TODO: Support both/multiple user data pieces
   USERDATAJSON=""
	if test -n "$USERDATA"; then
		if test "${USERDATA:0:13}" != "#cloud-config"; then echo "WARN: user-data string does not start with #cloud-config" 1>&2; fi
		USERDATAJSON="
		\"user_data\": \""$(echo "$USERDATA" | base64 -w0)"\","
	fi
	if test -n "$USERDATAFILE"; then
		if test -n "$USERDATAJASON"; then echo "WARN: user-data-file overrides string" 1>&2; fi
		if test "`head -n1 $USERDATAFILE`" != "#cloud-config"; then echo "WARN: user-data-file does not start with #cloud-config" 1>&2; fi
		USERDATAJSON="
		\"user_data\": \""$(base64 -w0 "$USERDATAFILE")"\","
	fi

	SECUGROUPIDS=""
	for id in ${SECUGROUP//,/ }; do
		SECUGROUPIDS="$SECUGROUPIDS { \"id\": \"$id\" },"
	done
	SECUGROUPIDS="${SECUGROUPIDS%,}"
}

ECSparamComplete()
{
	if [ "$IMAGE_ID" == "" ]; then
		if test -z "$BOOT_VOL"; then
			echo "Image definition not Correct ! Check avaliable images with following command:" 1>&2
			echo 'otc images list' 1>&2
		fi
	fi
	if [ "$INSTANCE_TYPE" == "" ]; then
		echo "Instance Type definition not Correct ! Please check avaliable flavors  with following command:" 1>&2
		echo 'otc ecs flavor-list' 1>&2
		exit 1
	fi
	if [ -n "$1" -a "$VPCID" == "" ]; then
		echo "VPC definition not Correct ! Please check avaliable VPCs  with following command:" 1>&2
		echo 'otc vpc list' 1>&2
		exit 1
	fi
	if [ -n "$1" -a "$SECUGROUP" == "" ]; then
		echo "Security Group definition not Correct ! Please check avaliable security group with following command:" 1>&2
		echo 'otc security-group list' 1>&2
		exit 1
	fi
	if [ "$SUBNETID" == "" ]; then
		echo "Subnet definition not Correct ! Please check avaliable subnets with following command:" 1>&2
		echo 'otc subnet list' 1>&2
		exit 1
	fi
}

ECSoptional()
{
	# composing os:scheduler_hints
	# using:
	# --tenancy $TENANCY
	# --dedicated-host|dedicated-host-id $DEDICATED_HOST_ID
	if test -n "$DEDICATED_HOST_ID"; then
		if ! is_uuid "$DEDICATED_HOST_ID"; then
			local DEH="$(uriencode $DEDICATED_HOST_ID)"
			DEDICATED_HOST_ID=$(curlgetauth $TOKEN "$AUTH_URL_DEH/v1.0/$OS_PROJECT_ID/dedicated-hosts?name=$DEH" | jq '.dedicated_hosts[].dedicated_host_id' | tr -d '"')
			if !  is_uuid "$DEDICATED_HOST_ID"; then
				echo "$DEDICATED_HOST_ID is not a valid UUID"
				exit 1
			fi
		fi
		if test -n "$TENANCY"; then
			SCHDHINT=",
		\"os:scheduler_hints\": {
			\"tenancy\": \"$TENANCY\",
			\"dedicated_host_id\": \"$DEDICATED_HOST_ID\"
		},"
		else
			SCHDHINT=",
		\"os:scheduler_hints\": {
			\"tenancy\": \"dedicated\",
			\"dedicated_host_id\": \"$DEDICATED_HOST_ID\"
		},"
		fi
	else
		if test -n "$TENANCY"; then
			SCHHINT=",
		\"os:scheduler_hints\": {
			\"tenancy\": \"$TENANCY\"
		},"
		fi
	fi

	if test -n "$KEYNAME"; then
		OPTIONAL="$OPTIONAL
		\"key_name\": \"$KEYNAME\","
	fi
	if test -n "$ADMINPASS"; then
		OPTIONAL="$OPTIONAL
		\"adminPass\": \"$ADMINPASS\","
	fi
	#OPTIONAL="$OPTIONAL \"__vnckeymap\": \"en\","
	if test -n "$METADATA_JSON"; then
		OPTIONAL="$OPTIONAL
		\"metadata\": { $METADATA_JSON },"
		echo "WARN: metadata passing not supported on ECS creation via Huawei API" 1>&2
	fi
	if test "$OTC_FORCEVPCTAG" == "1"; then
		if test -n "$TAGS"; then
			OPTIONAL="$OPTIONAL
		\"tags\": [ $(keyval2list $VPCID,$TAGS) ],"
		else
			OPTIONAL="$OPTIONAL
		\"tags\": [ \"$VPCID\" ],"
		fi
	else
		if test -n "$TAGS"; then
			OPTIONAL="$OPTIONAL
		\"tags\": [ $(keyval2list $TAGS) ],"
		fi
	fi

	if test -n "$DESCRIPTION"; then
		OPTIONAL="$OPTIONAL
		\"description\": \"$DESCRIPTION\", "
	fi

	if test -n "$AUTORECOV"; then
		OPTIONAL="$OPTIONAL
		\"extendparam\": { \"support_auto_recovery\": \"$AUTORECOV\" },"
	fi

	if test -n "$SCHEDHINT"; then
		SCHDHINT=",
	\"os:scheduler_hints\": $SCHEDHINT"
	fi

}

ECSmoreNICs()
{
	MORENICS=""
	if test -z "$1"; then return; fi
	SUBNETIDOLD="$SUBNETID"
	OLDIFS="$IFS"; IFS=","
	for sub in $1; do
		subn=${sub%%:*}
		fixed=${sub#*:}
		if ! is_uuid "$subn"; then convertSUBNETNameToId "$subn"; subn="$SUBNETID"; fi
		if test "$fixed" == "$sub"; then
			MORENICS="$MORENICS, { \"uuid\": \"$subn\" }"
		else
			MORENICS="$MORENICS, { \"uuid\": \"$subn\", \"fixed_ip\": \"$fixed\" }"
		fi
	done
	IFS="$OLDIFS"
	SUBNETID="$SUBNETIDOLD"
}

ECSCreate()
{
	getPersonalizationJSON
	ECScommonSettings

	OPTIONAL=""
	if [ "$CREATE_ECS_WITH_PUBLIC_IP" == "true" ]; then
		# TODO: have to got from param
		OPTIONAL="$OPTIONAL
		\"publicip\": {
			\"eip\": {
				\"iptype\": \"5_bgp\",
				\"bandwidth\": { \"size\": $BANDWIDTH, \"sharetype\": \"PER\", \"chargemode\": \"traffic\" }
			}
		},"
	elif [ -n "$EIP" ]; then
		convertEipToId $EIP
		if [ "$EIP_STATUS" != "DOWN" ]; then
			echo "ERROR: Status of EIP $EIP_ID ($EIP_IP) must be DOWN, is $EIP_STATUS" 1>&2
			exit 2
		fi
		OPTIONAL="$OPTIONAL
		\"publicip\": { \"id\": \"$EIP_ID\" },"
	fi

	ECSoptional

	local FIXEDIPJSON=""
	if test -n "$FIXEDIP"; then
		FIXEDIPJSON=", \"ip_address\": \"$FIXEDIP\""
	fi
	if test -n "$DATADISKS"; then
		DATA_VOLUMES="
			\"data_volumes\": [ $(build_data_volumes_json $DATADISKS) ],"
	fi
	# multi-NIC
	ECSmoreNICs "$MORESUBNETS"

	local REQ_CREATE_VM='{
	"server": {
		"availability_zone": "'"$AZ"'",
		"name": "'"$INSTANCE_NAME"'",
		"imageRef": "'"$IMAGE_ID"'",
		"root_volume": { "volumetype": "'"$VOLUMETYPE"'"'$DISKSIZE' }, '$DATA_VOLUMES'
		"flavorRef": "'"$INSTANCE_TYPE"'", '"$PERSONALIZATION"' '"$USERDATAJSON"'
		"vpcid": "'"$VPCID"'",
		"security_groups": [ '"$SECUGROUPIDS"' ],
		"nics": [ { "subnet_id": "'"$SUBNETID"'" '"$FIXEDIPJSON"' } '"$MORENICS"' ], '"$OPTIONAL"'
		"count": '$NUMCOUNT' '$SCHDHINT'
	}
}'

	echo "$REQ_CREATE_VM"

	ECSparamComplete 1

	export ECSTASKID
	ECSTASKID=`curlpostauth "$TOKEN" "$REQ_CREATE_VM" "$AUTH_URL_ECS_CLOUD" | jq '.job_id' | cut -d':' -f 2 | tr -d '" '; return ${PIPESTATUS[0]}`
	# this lines for DEBUG
	#return ${PIPESTATUS[0]}
}

waitVM()
{
	ECSID=$1
	local ctr err JSON STATUS PSTATUS PROGRESS PPROGRESS PT=""
	declare -i ctr=0
	declare -i err=0
	while test $ctr -le 900; do
		JSON=$(curlgetauth $TOKEN "$AUTH_URL_ECS/$ECSID")
		if test $? != 0; then
			let err+=1
			if test $err -ge 5; then echo -e "\nERROR: Poll ECS status err"; exit 2; fi
		fi
		STATUS=$(echo "$JSON" | jq '.server.status' | tr -d '"')
		if test "$STATUS" == "ACTIVE"; then echo -e "\r#$ECSID: ACTIVE "; break; fi
		PROGRESS=$(echo "$JSON" | jq '.server.progress' | tr -d '"')
		if test "$STATUS" != "$PSTATUS" -o "$PROGRESS" != "$PPROGRESS"; then
			echo -en "\r#$ECSID: $STATUS $PROGRESS $PT"
			PSTATUS="$STATUS"; PPROGRESS="$PROGRESS"
		fi
		if test "$STATUS" = "ERROR"; then
			echo
			echo "$JSON" | jq '.server.fault'
			exit 2
		fi
		echo -n "."
		sleep 2
		let ctr+=1
		PT=".$PT"
	done
}


build_data_volumes_bdmv2()
{
	local info_str=$1

	local DATA_VOLUMES=""
	disks=(${info_str//,/ })
	for disk in "${disks[@]}"; do
		info=(${disk//:/ })
		DATA_VOLUMES="$DATA_VOLUMES,
		 { \"source_type\": \"blank\", \"destination_type\": \"volume\", \"volume_size\": ${info[1]}, \"volume_type\": \"${info[0]}\""
		# TODO: tags
		#if test -n "$TAGS" -a -n "$INHERIT_TAGS"; then DATA_VOLUMES="$DATA_VOLUMES, \"tag\":$(keyval2list $TAGS | sed 's/,.*$//')"; fi
		DATA_VOLUMES="$DATA_VOLUMES }"
   done
	echo "$DATA_VOLUMES"
}

createBDMv2()
{
	if test -n "$IMAGE_ID"; then
		# Boot from image, if possible ...
		DISKMAPPING="\"imageRef\": \"$IMAGE_ID\","
		# Get Image disk size
		IMGDISKSZ="$(curlgetauth $TOKEN $AUTH_URL_IMAGES/$IMAGE_ID | jq '.min_disk')"
		# If we have a sigle (SATA) disk with default size, we are done ...
		if test -z "$DISKSIZE" -o "$ROOTDISKSIZE" == "$IMGDISKSZ" &&
			test -z "$VOLUMETYPE" -o "$VOLUMETYPE" == "SATA" &&
			test -z "$DATADISKS"; then
			return
		fi
	fi
	if test -n "$IMAGE_ID"; then
		# No such luck, we need to build a real block_device_mapping_v2
		if test -z "$ROOTDISKSIZE"; then ROOTDISKSIZE=$IMGDISKSZ; fi
		DISKMAPPING="\"block_device_mapping_v2\": ["
		# Boot disk
		DISKMAPPING="$DISKMAPPING
			 { \"boot_index\": 0, \"source_type\": \"image\",
			   \"uuid\": \"$IMAGE_ID\", \"destination_type\": \"volume\",
			   \"volume_size\": $ROOTDISKSIZE, \"delete_on_termination\": true"
		# Note: This is not yet supported by OTC
		#if test -n "$TAGS" -a -n "$INHERIT_TAGS"; then DISKMAPPING="$DISKMAPPING, \"tag\":$(keyval2list $TAGS | sed 's/,.*$//')"; fi
		if test -n "$VOLUMETYPE" -a "$VOLUMETYPE" != "SATA"; then DISKMAPPING="$DISKMAPPING, \"volume_type\": \"$VOLUMETYPE\""; fi
	else
		if ! is_uuid "$BOOT_VOL"; then BOOT_VOL="$(curlgetauth $TOKEN $CINDER_URL/volumes?name=$(uriencode $BOOT_VOL) | jq .volumes[].id | tr -d '"')"; fi
		DISKMAPPING="\"block_device_mapping_v2\": [
			{ \"boot_index\": 0, \"source_type\": \"volume\", \"delete_on_termination\": false,
			  \"uuid\": \"$BOOT_VOL\""
	fi
	DISKMAPPING="$DISKMAPPING }$(build_data_volumes_bdmv2 $DATADISKS)"
	# Allow attaching existing disks
	if test "$NUMCOUNT" = 1 -a -n "$DEV_VOL"; then
		for dev_vol in $(echo $DEV_VOL | sed 's/,/ /g'); do
			EVS_ID="${dev_vol#*:}"
			if ! is_uuid "$EVS_ID"; then convertEVSNameToId $EVS_ID; fi
			DISKMAPPING="$DISKMAPPING,
		 { \"source_type\": \"volume\", \"destination_type\": \"volume\", \"uuid\": \"$EVS_ID\", \"device_name\": \"${dev_vol%%:*}\" }"
		done
	fi
	DISKMAPPING="$DISKMAPPING
		],"
}

inheritTags()
{
	if test -n "$TAGS" -a -n "$INHERIT_TAGS"; then
		VOLS=$(curlgetauth $TOKEN $AUTH_URL_ECS/$ECSID | jq '.server | .["os-extended-volumes:volumes_attached"][].id' | tr -d '"')
		echo "Note: Tag volumes $VOLS" 1>&2
		TAGJSON="$(keyval2json $TAGS)"
		for VOL in $VOLS; do
			curlpostauth $TOKEN "{ \"tags\": { $TAGJSON } }" "$CINDER_URL/os-vendor-tags/volumes/$VOL" >/dev/null
		done
	fi
}

# Create VM by nova v2 API
ECSCreatev2()
{
	getPersonalizationJSON
	ECScommonSettings
	ECSoptional
	ECSparamComplete
	if test $NUMCOUNT != 1; then
		COUNT="\"min_count\": $NUMCOUNT, \"max_count\": $NUMCOUNT,"
	fi
	# multi-NIC
	SN="$SUBNETID"
	if test -n "$FIXEDIP"; then SN="$SN:$FIXEDIP"; fi
	if test -n "$MORESUBNETS"; then SN="$SN,$MORESUBNETS"; fi
	ECSmoreNICs "$SN"
	MORENICS="${MORENICS#,}"

	# FIXME: We pass SG IDs as names here ... Seems to work.
	if test -n "$SECUGROUPIDS"; then SG="\"security_groups\": [ $( echo $SECUGROUPIDS | sed 's/\"id\":/\"name\":/g' ) ],"; fi

	# volume treatment
	createBDMv2

	local REQ_CREATE_VM="{
	\"server\": {
		\"availablity_zone\": \"$AZ\",
		\"name\": \"$INSTANCE_NAME\",
		\"flavorRef\": \"$INSTANCE_TYPE\",
		$DISKMAPPING
		$SG
		$PERSONALIZATION $USERDATAJSON $OPTIONAL
		$COUNT
		\"networks\": [ $MORENICS ]
	}$SCHDHINT
}"
	echo "$REQ_CREATE_VM"
	OUTPUT=`curlpostauth "$TOKEN" "$REQ_CREATE_VM" "$AUTH_URL_ECS"`
	RC=$?
	if test $RC != 0; then echo "ERROR creating VM" 1>&2; exit $RC; fi
	ECSID=$(echo "$OUTPUT" | jq '.server.id' | tr -d '"')
	#echo "$OUTPUT" | jq '.'
	if test -z "$ECSID"; then exit 2; fi
	# EIP
	if test "$CREATE_ECS_WITH_PUBLIC_IP" == "true"; then
		EIP=$(PUBLICIPSCreate | jq '.id' | tr -d '"')
		if test ${PIPESTATUS[0]} != 0; then echo "WARNING: EIP allocation failed" 1>&2; EIP=""; else sleep 2; fi
	fi
	if test -n "$EIP"; then BindPublicIpToCreatingVM; fi
	# Wait
	if test -n "$TAGS" -a -n "$INHERIT_TAGS"; then WAIT_FOR_JOB="true"; fi
	if test "$WAIT_FOR_JOB" == "true"; then waitVM $ECSID; fi
	# TODO: Manual tag inheritance, like on v1 API
	# FIXME: unfortunately we infect DEV_VOLUMES
	inheritTags
	echo "ECS ID: $ECSID"
}


ECSAction()
{
	if test -z "$ECSACTIONTYPE"; then ECSACTIONTYPE="SOFT"; fi
	local REQ_ECS_ACTION_VM='
	{
		"'"$ECSACTION"'": {
			"type":"'"$ECSACTIONTYPE"'",
			"servers": [ { "id": "'"$ECSACTIONSERVERID"'" } ]
		}
	}'
	#echo $REQ_ECS_ACTION_VM
	local ECSRESP
	ECSRESP=$(curlpostauth "$TOKEN" "$REQ_ECS_ACTION_VM" "$AUTH_URL_ECS_CLOUD_ACTION")
	if test $? != 0; then return 9; fi
	local ECSTASKID=$(echo "$ECSRESP" | jq .job_id | tr -d '" ')
	WaitForTask $ECSTASKID
	return $?
}

# OpenStack API (unused)
ECSStop()
{
	local REQ="{\"os-stop\":{}}"
	local ECS_ACTION_STOP="$NOVA_URL/servers/$ECSACTIONSERVERID/action"
	#echo $ECS_ACTION_STOP
	curlpostauth "$TOKEN" "$REQ" "$ECS_ACTION_STOP"
	#return $?
}

setAutoRecov()
{
	if test "$AUTORECOV" != "true" -a "$AUTORECOV" != "false"; then echo "ERROR: --autorecovery needs to be set to true or false" 1>&2; exit 1; fi
	curlputauth $TOKEN "{ \"support_auto_recovery\": \"$AUTORECOV\" }" "$AUTH_URL_ECS_CLOUD/$1/autorecovery"
}

appendparm()
{
	if test -z "$PARMS"; then
		PARMS="$1"
	else
		PARMS="$PARMS, $1"
	fi
}

ECSUpdate()
{
	#if test "$1" = "-r"; then REPLACE=1; shift; fi
	if ! is_uuid "$1"; then convertECSNameToId "$1"; else ECS_ID="$1"; fi
	if test "$2" = "-r"; then REPLACE=1; shift; fi
	if test -n "$2"; then shift; echo "WARN: ignoring options at wrong position $@" 1>&2; fi
	local PARMS=""
	local RC=0
	if test -n "$IMAGENAME"; then appendparm "\"image\": \"$IMAGENAME\""; fi
	if test -n "$INSTANCE_NAME"; then appendparm "\"name\": \"$INSTANCE_NAME\""; fi
	#if test -n "$METADATA_JSON"; then appendparm "\"metadata\": { $METADATA_JSON }"; fi
	#if test -n "$TAGS"; then appendparm "\"tags\": [ $(keyval2list $TAGS) ]"; fi
	OLDIFS="$IFS"; IFS=","
	for prop in $PROPS; do
		appendparm "\"${prop%%=*}\": \"${prop#*=}\""
	done
	IFS="$OLDIFS"
	if test -n "$PARMS"; then
		curlputauth $TOKEN "{ \"server\": { $PARMS } }" "$AUTH_URL_ECS/$ECS_ID" | jq -r '.'
		RC=${PIPESTATUS[0]}
	fi
	if test -n "$METADATA_JSON"; then
		if test "$REPLACE" = 1; then
			curlputauth $TOKEN "{ \"metadata\": { $METADATA_JSON } }" "$AUTH_URL_ECS/$ECS_ID/metadata" | jq -r '.'
		else
			curlpostauth $TOKEN "{ \"metadata\": { $METADATA_JSON } }" "$AUTH_URL_ECS/$ECS_ID/metadata" | jq -r '.'
		fi
		if test $RC = 0; then RC=${PIPESTATUS[0]}; fi
	fi
	if test -n "$TAGS"; then
		if test "$REPLACE" = 1; then
			curlputauth $TOKEN "{ \"tags\": [ $(keyval2list $TAGS) ] }" "$AUTH_URL_ECS/$ECS_ID/tags" | jq -r '.'
			if test $RC = 0; then RC=${PIPESTATUS[0]}; fi
		else
			OLDIFS="$IFS"
			IFS=","
			for tag in $TAGS; do
				curlputauth $TOKEN "" "$AUTH_URL_ECS/$ECS_ID/tags/${tag/=/.}"
				R=$?; if test $RC = 0; then RC=$R; fi
			done
		fi
	fi
	if test -n "$INSTANCE_TYPE" -a -n "$FLAVORSET"; then
		curlpostauth $TOKEN "{ \"resize\": { \"flavorRef\": \"$INSTANCE_TYPE\" } }" "$AUTH_URL_ECS/$ECS_ID/action" | jq -r '.'
		#curlpostauth $TOKEN "{ \"resize\": { \"flavorRef\": \"$INSTANCE_TYPE\" } }" "$AUTH_URL_ECS_CLOUD/$ECS_ID/resize" | jq -r '.'
		if test $RC = 0; then RC=${PIPESTATUS[0]}; fi
   fi
	if test -n "$AUTORECOV"; then setAutoRecov $ECS_ID; fi
	return $RC
}

ECSDelete()
{
	local DEV_VOL="" delete_publicip="true" delete_volume="false" id ecs
	local IDS=""
	while [ $# -gt 0 ]; do
		case "$1" in
			--umount)    DEV_VOL="$2"           ; shift 2;;##### works only if $ecs is a name, not an id
			--keepEIP)   delete_publicip="false"; shift  ;;
			--delVolume) delete_volume="true"   ; shift  ;;
			--wait)      WAIT_FOR_JOB="true"    ; shift  ;;
			--nowait)    WAIT_FOR_JOB="false"   ; shift  ;;
			--rename)    DELRENAME="true"       ; shift  ;;
			*)           break;;
		esac
	done
	ERR=0
	for ecs in $@; do
		unset NAME
		if ! is_uuid "$ecs"; then
			NAME="$ecs"
			QNAME="$(uriencode $NAME)"
			ecs=`curlgetauth $TOKEN "$AUTH_URL_ECS?name=$QNAME" | jq '.servers[] | select(.name == "'$NAME'") | .id' | tr -d '" ,'; return ${PIPESTATUS[0]}`
			if test $? != 0 -o -z "$ecs" -o "$ecs" = "null"; then
				echo "ERROR: ECSDelete: No such VM $NAME" 1>&2
				let ERR+=1
				continue
			fi
		fi
		# Can be multiple if specified by name and several exist ...
		for id in $ecs; do
			IDS="$IDS { \"id\": \"$id\" },"
			[ -n "$DEV_VOL" ] && ECSDetachVolumeListName "$id" "$DEV_VOL" ##### detach some external volumes before deleting the vm
			if [ -n "$DELRENAME" ]; then
				if test -z "$NAME"; then NAME=`curlgetauth $TOKEN "$AUTH_URL_ECS/$id" | jq '.server.name' | tr -d '"'`; fi
				curlputauth $TOKEN "{ \"server\": { \"name\": \"DEL_$NAME\" } }" "$AUTH_URL_ECS/$id" >/dev/null
			fi
		done
	done
	##### TODO: we have to wait here until detachments were finished -- otherwize we run into a deadlock!
	IDS="${IDS%,}"
	if test -z "$IDS"; then echo "No VMs to delete found" 1>&2; exit 1; fi
	local REQ_ECS_DELETE='{
		"servers": [ '$IDS' ],
		"delete_publicip": '$delete_publicip',
		"delete_volume": '$delete_volume'
	}'
	#echo $REQ_ECS_DELETE
	local ECSRESP
	ECSRESP=`curlpostauth "$TOKEN" "$REQ_ECS_DELETE" "$AUTH_URL_ECS_CLOUD_DELETE"`
	RC=$?
	ECSTASKID=`echo "$ECSRESP" | jq '.job_id' | cut -d':' -f 2 | tr -d '" '`
	if test -n "$ECSTASKID"; then
		echo "Delete task ID: $ECSTASKID"
	else
		echo "ERROR:" 1>&2
		echo "$ECSRESP" | jq '.[]' 1>&2
		return 1
	fi
	return $(($RC+$ERR))
}

EVSCreate()
{
	if test -n "$(echo "$VOLUME_NAME" | sed 's/^[0-9a-zA-Z_\-]*$//')"; then
		echo "ERROR: VOLUME_NAME may only contain letters, digits, _ and -" 1>&2
		exit 2
	fi

	if test -z "$AZ"; then
		if test -n "$SUBNETAZ"; then
			AZ="$SUBNETAZ"
		else
			echo "ERROR: Need to specify AZ (or derive from subnet)" 1>&2
			exit 2
		fi
	fi
	if test -n "$SUBNETAZ" -a "$SUBNETAZ" != "$AZ"; then
		echo "WARN: AZ ($AZ) does not match subnet's AZ ($SUBNETAZ)" 1>&2
	fi

	local OPTIONAL=""
	local META="$METADATA_JSON"
	if test -n "$META"; then META="$META, "; fi
	if test -n "$SHAREABLE"; then
		OPTIONAL="$OPTIONAL
			\"multiattach\": $SHAREABLE,"
	fi
	if test -n "$IMAGEREFID"; then
		OPTIONAL="$OPTIONAL
			\"imageRef\": \"$IMAGEREFID\","
	fi
	if test -n "$BACKUPID"; then
		OPTIONAL="$OPTIONAL
			\"backup_id\": \"$BACKUPID\","
	fi
	if test -n "$TAGS"; then
		OPTIONAL="$OPTIONAL
			\"tags\": { $(keyval2json $TAGS) },"
	fi
	if test -n "$CRYPTKEYID"; then META="$META \"__system__encrypted\": \"1\", \"__system__cmkid\": \"$CRYPTKEYID\","; fi
	if test -n "$SCSI"; then META="$META \"hw:passthrough\": \"true\",";  fi
	if test -n "$VBD";  then META="$META \"hw:passthrough\": \"false\","; fi
	META="${META%,}"
	if test -n "$META"; then OPTIONAL="$OPTIONAL \"metadata\": { $META },"; fi
	if test -z "$NUMCOUNT"; then NUMCOUNT=1; fi
	if test -z "$VOLUME_DESC"; then VOLUME_DESC=$VOLUME_NAME; fi

	local REQ_CREATE_EVS='{
		"volume": {
			"count": '$NUMCOUNT',
			"availability_zone": "'$AZ'",
			"description": "'$VOLUME_DESC'",
			"size": "'$ROOTDISKSIZE'",
			"name": "'$VOLUME_NAME'",
			'"$OPTIONAL"'
			"volume_type": "'$VOLUMETYPE'"
		}
	}'

	echo "$REQ_CREATE_EVS"

	if [ "$ROOTDISKSIZE" == "" ]; then
		echo "EVS volume size is not defined! Please define a size with --disk-size" 1>&2
		exit 1
	fi

	export EVSTASKID
	EVSTASKID=`curlpostauth "$TOKEN" "$REQ_CREATE_EVS" "$AUTH_URL_CVOLUMES" | jq '.job_id' | cut -d':' -f 2 | tr -d '" '; return ${PIPESTATUS[0]}`
	# this lines for DEBUG
	#return ${PIPESTATUS[0]}
}

EVSUpdate()
{
	if ! is_uuid "$1"; then convertEVSNameToId "$1"; else EVS_ID="$1"; fi
	local OPTIONAL=""
	local META="$METADATA_JSON"
	if test -n "$META"; then META="$META, "; fi
	if test -n "$SHAREABLE"; then
		OPTIONAL="$OPTIONAL
			\"multiattach\": $SHAREABLE,"
	fi
	if test -n "$CRYPTKEYID"; then META="$META \"__system__encrypted\": \"1\", \"__system__cmkid\": \"$CRYPTKEYID\","; fi
	if test -n "$SCSI"; then META="$META \"hw:passthrough\": \"true\","; fi
	if test -n "$VBD"; then META="$META \"hw:passthrough\": \"false\","; fi
	META="${META%,}"
	if test -n "$META"; then OPTIONAL="$OPTIONAL \"metadata\": { $META },"; fi
	if test -n "$VOLUME_NAME"; then OPTIONAL="$OPTIONAL \"name\": \"$VOLUME_NAME\","; fi
	if test -n "$VOLUME_DESC"; then OPTIONAL="$OPTIONAL \"description\": \"$VOLUME_DESC\","; fi

	if test -z "$OPTIONAL" -a -z "$TAGS"; then
		echo "WARN: No changes specified" 1>&2; exit 1
	fi

	if test -n "$OPTIONAL"; then
		curlputauth $TOKEN "{ \"volume\": { ${OPTIONAL%,} } }" "$AUTH_URL_VOLS/$EVS_ID" | jq -r '.'
	fi
	if test -n $TAGS; then
		#TAGS=`curlgetauth $TOKEN "${AUTH_URL_VOLS%/volumes}/os-vendor-tags/volumes/$EVS_ID"`
		if test "$REPLACE" == "1"; then
			curlputauth $TOKEN "{ \"tags\": { $(keyval2json $TAGS) } }" "${AUTH_URL_VOLS%/volumes}/os-vendor-tags/volumes/$EVS_ID" | jq -r '.'
		else
			curlpostauth $TOKEN "{ \"tags\": { $(keyval2json $TAGS) } }" "${AUTH_URL_VOLS%/volumes}/os-vendor-tags/volumes/$EVS_ID" | jq -r '.'
		fi
	fi
	return ${PIPESTATUS[0]}
}


EVSDelete()
{
	export EVSTASKID
	EVSTASKID=`curldeleteauth "$TOKEN" "$AUTH_URL_CVOLUMES/$@" | jq '.[]' | tr -d '" '; return ${PIPESTATUS[0]}`
	#return ${PIPESTATUS[0]}
}

VPCCreate()
{
	local TAGJSON=""
	if test -z "$VPCNAME" -a -n "$1"; then VPCNAME="$1"; fi
	# Description?
	if test -n "$TAGS"; then TAGJSON=",
			\"tags\": [ $(keyval2listasterix $TAGS) ] }"
	fi
	local REQ_CREATE_VPC='{
		"vpc": {
			"name": "'"$VPCNAME"'",
			"cidr": "'"$CIDR"'"'"$TAGJSON"'
		}
	}'
	export REQ_CREATE_VPC
	#echo $REQ_CREATE_VPC
	curlpostauth "$TOKEN" "$REQ_CREATE_VPC" "$AUTH_URL_VPCS" | jq '.[]'
	return ${PIPESTATUS[0]}
}

SUBNETCreate()
{
	# Calculate gateway_ip from CIDR if needed
	if test -z "$GWIP"; then
		NETIP=$(echo ${CIDR%/*}.0.0.0 | sed 's/\([0-9]*\)\.\([0-9]*\)\.\([0-9]*\)\.\([0-9]*\).*$/\1.\2.\3.\4/')
		LASTOCT=${NETIP##*.}
		GWIP=${NETIP%.*}.$((LASTOCT+1))
	fi
	if test -n "$AZ"; then AZJSON="\"availability_zone\": \"$AZ\","; fi
	local TAGJSON=""
	if test -n "$TAGS"; then TAGJSON="\"tags\": [ $(keyval2listasterix $TAGS) ],
"
	fi
	# Description?
	local REQ_CREATE_SUBNET='{
		"subnet": {
			"name": "'"$SUBNETNAME"'",
			"cidr": "'"$CIDR"'",
			"gateway_ip": "'$GWIP'",
			"dhcp_enable": "true",
			"primary_dns": "'"$PRIMARYDNS"'",
			"secondary_dns": "'"$SECDNS"'",
			'$AZJSON'
			'$TAGJSON'
			"vpc_id":"'"$VPCID"'"
		}
	}'
	#echo $REQ_CREATE_SUBNET
	curlpostauth "$TOKEN" "$REQ_CREATE_SUBNET" "$AUTH_URL_SUBNETS" | jq '.[]'
	return ${PIPESTATUS[0]}
}

PUBLICIPSCreate()
{
	local IPAD
	if test -z "$BANDWIDTH_NAME"; then BANDWIDTH_NAME="bandwidth-${BANDWIDTH}m-$$"; fi
	if test -n "$DOPEP"; then local EIPTP="5_ipv6"; else EIPTP="5_bgp"; fi
	if test -n "$IPADDR"; then IPAD=", \"ip_address\": \"$IPADDR\""; fi
	local REQ_CREATE_PUBLICIPS='{
		"publicip": {
			"type": "'$EIPTP'"'$IPAD'
		},
		"bandwidth": {
			"name": "'"$BANDWIDTH_NAME"'",
			"size": '$BANDWIDTH',
			"share_type": "PER"
		}
	}'

	#echo $REQ_CREATE_PUBLICIPS 1>&2
	curlpostauth "$TOKEN" "$REQ_CREATE_PUBLICIPS" "$AUTH_URL_PUBLICIPS" | jq '.[]'
	return ${PIPESTATUS[0]}
}

PUBLICIPSUpdate()
{
	if ! is_uuid "$1" && is_ip4 $1; then convertEIPtoID $1; else EIP=$1; fi
	#if test -z "$BANDWIDTH_NAME"; then BANDWIDTH_NAME="bandwidth-${BANDWIDTH}m-$$"; fi
	if test -n "$DOPEP"; then local EIPTP="5_ipv6"; else EIPTP="5_bgp"; fi
	if test -z "$BWID"; then BWID=$(curlgetauth $TOKEN $AUTH_URL_PUBLICIPS/$EIP | jq .publicip.bandwidth_id | tr -d '"'); fi
	if test -z "$BWID" -o "$BWID" == "null"; then echo "ERROR: No such public IP $EIP" 1>&2; exit 2; fi
	local REQ_UPDATE_BW='{
		"bandwidth": {
			"size": '$BANDWIDTH''
	if test -n "$BANDWIDTH_NAME"; then
		REQ_UPDATE_BW="$REQ_UPDATE_BW,
			\"name\": \"$BANDWIDTH_NAME\""
	fi
	REQ_UPDATE_BW="$REQ_UPDATE_BW
		}
}"
	#echo $REQ_CREATE_PUBLICIPS 1>&2
	curlputauth "$TOKEN" "$REQ_UPDATE_BW" "$NEUTRON_URL/v1/$OS_PROJECT_ID/bandwidths/$BWID" | jq '.[]'
	return ${PIPESTATUS[0]}
}

PUBLICIPSDelete()
{
	if ! is_uuid "$1" && is_ip4 $1; then convertEIPtoID $1; else EIP=$1; fi
	curldeleteauth "$TOKEN" "$AUTH_URL_PUBLICIPS/$EIP" | jq '.[]'
	return ${PIPESTATUS[0]}
}

getPortID()
{
	local OSIF OSIP
	OSIF=$(curlgetauth $TOKEN "$AUTH_URL_ECS/$1/os-interface" | jq '.interfaceAttachments[]'; exit ${PIPESTATUS[0]})
	RC=$?; if test $RC != 0; then return $RC; fi
	if test "$(echo $OSIF | jq '.port_state' | tr -d '"')" == ACTIVE; then
		OSIP=$(echo $OSIF | jq '.fixed_ips[0].ip_address' | tr -d '"')
		if test -n "$OSIP" -a "$OSIP" != "null"; then
			echo "$OSIF" | jq '.port_id' | tr -d '"'
		fi
	fi
}

BindPublicIpToCreatingVM()
{
	local PRTID
	convertEipToId "$EIP"
	if test "$EIP_STATUS" != "DOWN"; then
		echo "WARNING: Requested EIP $EIP_ID has wrong status $EIP_STATUS" 1>&2
	fi
	##### use ecs server id to attach volumes, external ip_addresses, ...
	while [ -z "$PRTID" ]; do sleep 5; PRTID=$(getPortID $ECSID); done
	PUBLICIPSBind "$EIP_ID" "$PRTID"
}

PUBLICIPSBind()
{
	if ! is_uuid "$1" && is_ip4 "$1"; then convertEIPtoID $1; else EIP=$1; fi
	local PORT_ID=$2
	if test -z "$PORT_ID" -a -n "$FIXEDPORT"; then PORT_ID="$FIXEDPORT"; fi
	# Add optional fixed IP to port conversion here
	if test -z "$PORT_ID" && is_ip4 "$FIXEDIP"; then PORT_ID="$FIXEDIP"; fi
	if ! is_uuid "$PORT_ID" && is_ip4 "$PORT_ID"; then
		PORT_ID=$(curlgetauth $TOKEN $NEUTRON_URL/v2.0/ports?fixed_ips=ip_address=$PORT_ID | jq ' .ports[] | .id' | tr -d '"')
	fi
	if test -z "$PORT_ID"; then echo "ERROR: Need port-id to which the public IP should be bound to." 1>&2; exit 1; fi
	local REQ_BIND_PUBLICIPS='{
		"publicip": {
			"port_id": "'"$PORT_ID"'"
		}
	}'

	echo $REQ_BIND_PUBLICIPS
	curlputauth "$TOKEN" "$REQ_BIND_PUBLICIPS" "$AUTH_URL_PUBLICIPS/$EIP" | jq '.[]'
	return ${PIPESTATUS[0]}
}

PUBLICIPSUnbind()
{
	if ! is_uuid "$1" && is_ip4 $1; then convertEIPtoID $1; else EIP=$1; fi
	local REQ_UNBIND_PUBLICIPS='{
		"publicip": {
			"port_id": ""
		}
	}'

	echo $REQ_UNBIND_PUBLICIPS
	curlputauth "$TOKEN" "$REQ_UNBIND_PUBLICIPS" "$AUTH_URL_PUBLICIPS/$EIP" | jq '.[]'
	return ${PIPESTATUS[0]}
}

convertEip6ToId()
{

	if test -n "$1"; then EIP="$1"; fi
	if is_uuid "$EIP"; then FILTER="?id=$EIP"; else FILTER="?public_ip_address=$EIP"; fi
	#setlimit; setapilimit 600 40 floatingips
	EIP_JSON=$(curlgetauth_pag $TOKEN "$NEUTRON_URL/v2.0/eip/floatingips_v6" | jq ".floatingips[]"; return ${PIPESTATUS[0]})
	if test $? != 0 -o -z "$EIP_JSON" -o "$EIP_JSON" = "null"; then
		echo "ERROR: No Floating IP $EIP found" 1>&2
		exit 3
	fi
	EIP_ID=$(echo "$EIP_JSON" | jq '.id' | tr -d '"')
	EIP_IP=$(echo "$EIP_JSON" | jq '.public_ip_address' | tr -d '"')
	EIP_STATUS=$(echo "$EIP_JSON" | jq '.status' | tr -d '"')
	export EIP_ID EIP_STATUS
	return 0
}

getPUBLICIPS6List()
{
	#curlgetauth $TOKEN "$AUTH_URL_PUBLICIPS?limit=500" | jq '.'
	#setlimit 500
	setlimit; setapilimit 600 40 publicips
	curlgetauth_pag $TOKEN "$NEUTRON_URL/v2.0/eip/floatingips_v6$PARAMSTRING" | jq '.floatingips[]  | .id +"   " +.floating_ip_address +"   " +.status+"   " +.fixed_ip_address +"   "+.router_id' | tr -d '"'
	return ${PIPESTATUS[0]}
}

getPUBLICIPS6Detail()
{
	if ! is_uuid "$1" && is_ip6 $1; then convertEIP6toID $1; else EIP=$1; fi
	curlgetauth $TOKEN "$NEUTRON_URL/v2.0/eip/floatingips_v6/$EIP" | jq '.'
	return ${PIPESTATUS[0]}
}

PUBLICIPS6Create()
{
	local IPAD
	if test -n "$IPADDR"; then IPAD=", \"floating_ip_address\": \"$IPADDR\""; fi
	if test -z "$EXTNETWORK"; then
		EXTNETWORK=$(curlgetauth $TOKEN "$NEUTRON_URL/v2.0/networks?router:external=true" | jq '.networks[].id' | tr -d '"')
	fi
	if test -n "$FIXEDIP"; then FIXED=", \"fixed_ip_address\": \"$FIXEDIP\""; fi
	if test -n "$FIXEDPORT"; then FIXED=", \"port_id\": \"$FIXEDPORT\""; fi
	if test -n "$DESCRIPTION"; then DESC=", \"description\": \"$DESCRIPTION\""; fi
	local REQ_CREATE_FLOATINGIP="{
		\"floatingip\": {
			\"floating_network_id\": \"$EXTNETWORK\" $FIXED $DESC
		}
	}"

	#echo $REQ_CREATE_PUBLICIPS 1>&2
	curlpostauth "$TOKEN" "$REQ_CREATE_FLOATINGIP" "$NEUTRON_URL/v2.0/eip/floatingips_v6" | jq -r '.'
	return ${PIPESTATUS[0]}
}

PUBLICIPS6Delete()
{
	if ! is_uuid "$1" && is_ip6 $1; then convertEIP6toID $1; else EIP=$1; fi
	curldeleteauth "$TOKEN" "$NEUTRON_URL/v2.0/eip/floatingips_v6/$EIP" | jq '.[]'
	return ${PIPESTATUS[0]}
}

PUBLICIPS6Bind()
{
	if ! is_uuid "$1" && is_ip6 $1; then convertEIP6toID $1; else EIP=$1; fi
	local PORT_ID=$2
	if test -z "$PORT_ID" -a -n "$FIXEDPORT"; then PORT_ID="$FIXEDPORT"; fi
	# TODO: Add optional fixed IP to port conversion here
	if test -z "$PORT_ID" -a -n "$FIXEDIP"; then PORT_ID="$FIXEDIP"; fi
	if ! is_uuid "$PORT_ID"; then
		PORT_ID=$(curlgetauth $TOKEN $NEUTRON_URL/v2.0/ports?fixed_ips=ip_address=$PORT_ID | jq ' .ports[] | .id' | tr -d '"')
	fi
if test -z "$PORT_ID"; then echo "ERROR: Need port-id to which the public IP should be bound to." 1>&2; exit 1; fi
	local REQ_BIND_FLOATINGIP='{
		"floatingip": {
			"port_id": "'"$PORT_ID"'"
		}
	}'

	echo $REQ_BIND_PUBLICIPS
	curlputauth "$TOKEN" "$REQ_BIND_FLOATINGIP" "$NEUTRON_URL/v2.0/eip/floatingips_v6/$EIP" | jq '.[]'
	return ${PIPESTATUS[0]}
}

PUBLICIPS6Unbind()
{
	if ! is_uuid "$1" && is_ip6 $1; then convertEIP6toID $1; else EIP=$1; fi
	local REQ_UNBIND_FLOATINGIP='{
		"floatingip": {
			"port_id": null
		}
	}'

	echo $REQ_UNBIND_PUBLICIPS
	curlputauth "$TOKEN" "$REQ_UNBIND_FLOATINGIP" "$NEUTRON_URL/v2.0/eip/floatingips_v6/$EIP" | jq '.[]'
	return ${PIPESTATUS[0]}
}


# $1 = TASKID
# $2 = Field to wait for
# $3 = PollFreq (s), default 2
# $4 = MaxWait (multiples of PollFreq), default 21
WaitForTaskField()
{
	if test -z "$1" -o "$1" = "null"; then echo "ERROR" 1>&2; return 1; fi
	local SEC=${3:-2}
	local MAXW=${4:-21}
	echo "Waiting for field $2 in job: $AUTH_URL_ECS_JOB/$1" 1>&2
	getECSJOBList $1
	local RESP="$ECSJOBSTATUSJSON"
	echo "#$RESP" 1>&2
	FIELD=$(echo $ECSJOBSTATUSJSON| jq "$2" 2>/dev/null | tr -d '"')
	declare -i ctr=0
	while [ $ctr -le $MAXW ] && [ "$ECSJOBSTATUS" == "RUNNING" ] || [ "$ECSJOBSTATUS" == "INIT" ]; do
		[ -n "$FIELD" -a "$FIELD" != "null" ] && break
		sleep $SEC
		getECSJOBList $1
		FIELD=$(echo $ECSJOBSTATUSJSON| jq "$2" 2>/dev/null | tr -d '"')
		if [ "$RESP" != "$ECSJOBSTATUSJSON" ]; then
			RESP="$ECSJOBSTATUSJSON"
			echo -e "\n#$RESP" 1>&2
		else
			echo -n "." 1>&2
		fi
		if test "$(echo $ECSJOBSTATUSJSON | jq '.status' | tr -d '"')" == "FAIL"; then
			#echo "ERROR: Job $ECSSUBTASKID failed" 1>&2
			#echo "$ECSJOBSTATUSJSON" | jq '.' 1>&2
			return 8
		fi
		let ctr+=1
	done
	echo $FIELD
	test -n "$FIELD" -a "$FIELD" != "null"
}

WaitForSubTask()
{
	ECSSUBTASKID=$(WaitForTaskField $1 ".entities.sub_jobs[].job_id" $2)
}

# Wait for task to completely finish (if WAIT_FOR_JOB==true),
# optionally output field ($4), otherwise don't wait
# $1 = TASKID
# $2 = PollFreq (s), default 2s
# $3 = MaxWait (in multiples of 2xPollFreq), default 2hrs
# $4 = Field to output (optional)
# $5 = URL to query for task status
# $6 = task command name
WaitForTaskGeneric()
{
	local SEC=${2:-2}
	# Timeout after 2hrs
	local DEFTOUT=$((1+3600/$SEC))
	local TOUT=$((2*${3:-$DEFTOUT}))
	unset FIELD
	if [ "$WAIT_FOR_JOB" == "true" ]; then
		echo "Waiting for Job:   $5/$1" 1>&2
		getJobList $1 $5

		local RESP="$JOBSTATUSJSON"
		if test -n "$4"; then FIELD=$(echo $JOBSTATUSJSON| jq "$4" 2>/dev/null | tr -d '"'); fi
		echo "#$RESP" 1>&2
		declare -i ctr=0
		while [ $ctr -le $TOUT ] && [ "$JOBSTATUS" == "RUNNING" -o "$JOBSTATUS" == "INIT" ]; do
			sleep $SEC
			getJobList $1 $5
			if test -n "$4"; then FIELD=$(echo $JOBSTATUSJSON| jq "$4" 2>/dev/null | tr -d '"'); fi
			if [ "$RESP" != "$JOBSTATUSJSON" ]; then
				RESP="$JOBSTATUSJSON"
				echo -e "\n#$RESP" 1>&2
			else
				echo -n "." 1>&2
			fi
			let ctr+=1
			if test "$(echo $JOBSTATUSJSON | jq '.status' | tr -d '"')" == "FAIL"; then
				#echo "ERROR: Job $SUBTASKID failed" 1>&2
				#echo "$JOBSTATUSJSON" | jq '.' 1>&2
				return 8
			fi
		done
		if [ $ctr -gt $TOUT ]; then echo "WARN: Task $1 timed out after 2hrs" 1>&2;
		elif [ -n "$FIELD" -a "$FIELD" != "null" ]; then echo "$FIELD"; fi
	else
		getJobList $1 $5
		echo "#$JOBSTATUSJSON" 1>&2
		echo "#Note: Not waiting for completion, use otc $6 show $1 to monitor and otc $6 wait to wait)"
	fi
}

# Wait for task to completely finish (if WAIT_FOR_JOB==true),
# optionally output field ($4), otherwise don't wait
# $1 = TASKID
# $2 = PollFreq (s), default 2s
# $3 = MaxWait (in multiples of 2xPollFreq), default 2hrs
# $4 = Field to output (optional)
WaitForTask()
{
	WaitForTaskGeneric "$1" "$2" "$3" "$4" "$AUTH_URL_ECS_JOB" "task"
}

# Wait for workspace job to completely finish (if WAIT_FOR_JOB==true),
# optionally output field ($4), otherwise don't wait
# $1 = JOBID
# $2 = PollFreq (s), default 2s
# $3 = MaxWait (in multiples of 2xPollFreq), default 2hrs
# $4 = Field to output (optional)
WaitForWorkspaceJob()
{
	WaitForTaskGeneric "$1" "$2" "$3" "$4" "$AUTH_URL_WORKSPACE_JOBS" "workspace-job"
}

# Wait for full completion if WAIT_FOR_JOB is "true", not at all if set to something else,
# wait for subtask if unset
# $1 = TASKID
# $2 = Field to wait for
# $3 = PollFreq (s), optional
# $4 = MAXWAIT (multiples of POLLFREQ), optional
WaitForTaskFieldOpt()
{
	if test -n "$WAIT_FOR_JOB"; then
		WaitForTask $1 $3 $4 "$2"
	else
		WaitForTaskField $1 "$2" $3 $4
	fi
}

# Does not seem to work :-(
DeleteTask()
{
	curldeleteauth "$TOKEN" "$AUTH_URL_ECS_JOB/$1"
	#return $?
}

getUserDomainIdFromIamResponse()
{
	tail -n1 | jq -r .token.user.domain.id
}

shortlistClusters()
{
	curlgetauth "$TOKEN" "$AUTH_URL_CCE/api/v1/clusters" | jq -r '.[] | .metadata.uuid+"   "+.metadata.name+"   "+.clusterStatus.status+"   "+.spec.az+"   "+.spec.vpc+"   "+.spec.subnet+"   "+.spec.clustertype+"   "+.k8s_version' 2>/dev/null
	return ${PIPESTATUS[0]}
}

createCluster()
{
	if test -z "$TYPE"; then
		echo "ERROR: cluster create needs --type" 1>&2; exit 1
	fi
	if test -z "$NAME" -a -n "$1"; then NAME="$1"; shift; fi
	REQ="{
	\"kind\": \"cluster\",
	\"apiVersion\": \"v1\""
	if test -n "$NAME"; then
		REQ="$REQ,
	\"metadata\": { \"name\": \"$NAME\" }"
	fi
	if test -z "$VPCID" -a -n "$VPCNAME"; then convertVPCNameToId "$VPCNAME"; fi
	if test -z "$VPCID"; then
		echo "ERROR: cluster create needs --vpc-name/-id" 1>&2; exit 1
	fi
	if test -z "$SUBNETID" -a -n "$SUBNETNAME"; then convertSUBNETNameToId "$SUBNETNAME"; fi
	if test -z "$SUBNETID"; then
		echo "ERROR: cluster create needs --subnet-name/-id" 1>&2; exit 1
	fi
	if test -z "$AZ" -a -n "$SUBNETAZ"; then
		AZ="$SUBNETAZ"
	fi
	REQ="$REQ,
	\"spec\": {
		\"vpc\": \"$VPCID\",
		\"subnet\": \"$SUBNETID\""
	if test -n "$DESCRIPTION"; then
		REQ="$REQ,
		\"description\": \"$DESCRIPTION\""
	fi
	if test -n "$AZ"; then
		REQ="$REQ,
		\"az\": \"$AZ\""
	fi
	if test -n "$SECUGROUP"; then
		REQ="$REQ,
		\"security_group_id\": \"$SECUGROUP\""
	fi
	REQ="$REQ,
		\"region\": \"$OS_REGION_NAME\",
		\"clustertype\": \"$TYPE\"
	}
	}"
	curlpostauth $TOKEN "$REQ" "$AUTH_URL_CCE/api/v1/clusters"
}

listClusters()
{
	curlgetauth "$TOKEN" "$AUTH_URL_CCE/api/v1/clusters" | jq '.'
	return ${PIPESTATUS[0]}
}

deleteCluster()
{
	ID=$1
	if ! is_uuid "$ID"; then ID=$(curlgetauth $TOKEN "$AUTH_URL_CCE/api/v1/clusters" | jq ".[].metadata | select(.name == \"$ID\") | .uuid" | tr -d '"'); fi
	if test -z "$ID" -o "$ID" = "null"; then echo "ERROR: No such cluster $1" 1>&2; exit 3; fi
	curldeleteauth "$TOKEN" "$AUTH_URL_CCE/api/v1/clusters/$ID" "Content-Type: application/json"
}

showCluster()
{
	ID=$1
	if ! is_uuid "$ID"; then ID=$(curlgetauth $TOKEN "$AUTH_URL_CCE/api/v1/clusters" | jq ".[].metadata | select(.name == \"$ID\") | .uuid" | tr -d '"'); fi
	curlgetauth "$TOKEN" "$AUTH_URL_CCE/api/v1/clusters/$ID" | jq '.'
	return ${PIPESTATUS[0]}
}

listClusterHosts()
{
	ID=$1
	if ! is_uuid "$ID"; then ID=$(curlgetauth $TOKEN "$AUTH_URL_CCE/api/v1/clusters" | jq ".[].metadata | select(.name == \"$ID\") | .uuid" | tr -d '"'); fi
	if test -z "$ID" -o "$ID" = "null"; then echo "ERROR: No such cluster $1" 1>&2; exit 3; fi
	#curlgetauth "$TOKEN" "$AUTH_URL_CCE/api/v1/clusters/$ID/hosts" | jq '.'
	curlgetauth "$TOKEN" "$AUTH_URL_CCE/api/v1/clusters/$ID/hosts" | jq -r '.spec.hostList[] | .spec.hostid+"   "+.message+"   "+.status+"   "+.spec.privateip+"   "+.spec.sshkey' 2>/dev/null
	return ${PIPESTATUS[0]}
}

showClusterHost()
{
	ID=$1
	if ! is_uuid "$ID"; then ID=$(curlgetauth $TOKEN "$AUTH_URL_CCE/api/v1/clusters" | jq ".[].metadata | select(.name == \"$ID\") | .uuid" | tr -d '"'); fi
	curlgetauth "$TOKEN" "$AUTH_URL_CCE/api/v1/clusters/$ID/hosts/$2" | jq '.'
	return ${PIPESTATUS[0]}
}

createClusterHosts()
{
	ID=$1
	if ! is_uuid "$ID"; then ID=$(curlgetauth $TOKEN "$AUTH_URL_CCE/api/v1/clusters" | jq ".[].metadata | select(.name == \"$ID\") | .uuid" | tr -d '"'); fi
	if test -z "$ID" -o "$ID" = "null"; then echo "ERROR: No such cluster $1" 1>&2; exit 3; fi
	NO=$2
	if test -z "$NO"; then NO=1; fi
	if test -z "$DISKS"; then
		if test -z "$ROOTDISKSIZE" -o -z "$VOLUMETYPE"; then
			echo "ERROR: host create needs --disks (or --disktype + --disksize + --datadisks)" 1>&2; exit 1
		fi
		DISKS=$VOLUMETYPE:$ROOTDISKSIZE
		if test -n "$DATADISKS"; then DISKS="$DISKS,$DATADISKS"; fi
	fi
	unset TP
	DISKDESC="\"volume\": ["
	DDISK="$DISKS"
	while test -n "$DDISK"; do
		entry=${DDISK%%,*}
		if test "${DDISK#*,}" == "$DDISK"; then DDISK=""; else DDISK="${DDISK#*,}"; fi
		if test -z "$TP"; then TP=root; else TP=data; fi
		DISKDESC="$DISKDESC
		  {
			\"diskType\": \"$TP\",
			\"diskSize\": ${entry##*:},
			\"volumeType\": \"${entry%:*}\"
		  },"
	done
	DISKDESC="${DISKDESC%,}
		]"
	if test -z "$KEYNAME"; then
		echo "ERROR: host create needs --key-name" 1>&2; exit 1
	fi
	if test -z "$INSTANCE_TYPE"; then
		echo "ERROR: host create needs --instance-type" 1>&2; exit 1
	fi
	REQ="{
	\"kind\": \"host\",
	\"apiVersion\": \"v1\",
	\"spec\": {
		\"flavor\": \"$INSTANCE_TYPE\""
	if test -n "$NAME"; then
		REQ="$REQ,
		\"label\": \"$NAME\""
	fi
	REQ="$REQ,
		$DISKDESC,
		\"sshkey\": \"$KEYNAME\""
	if test "$SNAT" == "1"; then
		REQ="$REQ,
		\"snat\": true"
	fi
	if test -n "$AZ"; then
		REQ="$REQ,
		\"az\": \"$AZ\""
	fi
	if test -n "$TAGS"; then
		REQ="$REQ,
		\"tags\": [ $(keyval2list $TAGS) ]"
	fi
	REQ="$REQ
	},
	\"replicas\": $NO
}"
	#echo "$REQ"
	curlpostauth $TOKEN "$REQ" "$AUTH_URL_CCE/api/v1/clusters/$ID/hosts"
}

deleteClusterHosts()
{
	ID=$1
	if ! is_uuid "$ID"; then ID=$(curlgetauth $TOKEN "$AUTH_URL_CCE/api/v1/clusters" | jq ".[].metadata | select(.name == \"$ID\") | .uuid" | tr -d '"'); fi
	if test -z "$ID" -o "$ID" = "null"; then echo "ERROR: No such cluster $1" 1>&2; exit 3; fi
	shift
	REQ="{ \"hosts\": ["
	for host in "$@"; do
		REQ="$REQ { \"name\": \"$host\" },"
	done
	REQ="${REQ%,} ] }"
	curldeleteauthwithjsonparameter $TOKEN "$REQ" "$AUTH_URL_CCE/api/v1/clusters/$ID/hosts"
}


# CES
listMetrics()
{
	local PARM=""
	if test -n "$1"; then PARM="?namespace=$1"; fi
	if test -n "$2"; then PARM="$PARM&metric_name=$2"; fi
	if test -n "$3"; then PARM="$PARM&dim.0=${3/=/,}"; fi
	if test -n "$4"; then PARM="$PARM&dim.1=${4/=/,}"; fi
	if test -n "$5"; then PARM="$PARM&dim.2=${5/=/,}"; fi
	if test "${PARM:0:1}" = "&"; then PARM="?${PARM:1}"; fi
	#curlgetauth "$TOKEN" "$AUTH_URL_CES/V1.0/$OS_PROJECT_ID/metrics$PARM" | jq '.'
	# TODO: More than one metric possible
	curlgetauth "$TOKEN" "$AUTH_URL_CES/V1.0/$OS_PROJECT_ID/metrics$PARM" | jq -r 'def str(v): v|tostring; .metrics[] | .namespace+"   "+.metric_name+"   "+.unit+"   "+str(.dimensions[].value)' | arraytostr
	return ${PIPESTATUS[0]}
}

listFavMetrics()
{
	curlgetauth "$TOKEN" "$AUTH_URL_CES/V1.0/$OS_PROJECT_ID/favorite-metrics" | jq '.'
	return ${PIPESTATUS[0]}
}

showMetrics()
{
	local NOW=$(date +%s)
	local START=$(echo "scale=0; (${3/NOW/$NOW})*1000" | bc)
	local STOP=$(echo "scale=0; (${4/NOW/$NOW})*1000" | bc)
	if test -n "$7"; then DIM="&dim.0=${7/=/,}"; else DIM=""; fi
	if test -n "$8"; then DIM="$DIM&dim.1=${8/=/,}"; fi
	if test -n "$9"; then DIM="$DIM&dim.2=${9/=/,}"; fi
	curlgetauth "$TOKEN" "$AUTH_URL_CES/V1.0/$OS_PROJECT_ID/metric-data?namespace=$1&metric_name=$2&from=$START&to=$STOP&period=$5&filter=$6$DIM" | jq '.' | sed -e 's/"timestamp": \([0-9]*\)\([0-9]\{3\}\),/"timestamp": \1.\2,/' -e 's/"timestamp": \([0-9]*\)\.000,/"timestamp": \1,/'
	return ${PIPESTATUS[0]}
}

listAlarms()
{
	#curlgetauth "$TOKEN" "$AUTH_URL_CES/V1.0/$OS_PROJECT_ID/alarms" | jq '.'
	#TODO: Show multiple dimensions if available
	curlgetauth "$TOKEN" "$AUTH_URL_CES/V1.0/$OS_PROJECT_ID/alarms" | jq -r 'def str(v): v|tostring; .metric_alarms[] | .alarm_id+"   "+.alarm_name+"   "+str(.alarm_enabled)+"   "+str(.metric.dimensions[].value)+"   "+.metric.namespace+" "+.metric.metric_name+" "+.condition.comparison_operator+" "+str(.condition.value)+" "+.condition.unit ' | arraytostr
	return ${PIPESTATUS[0]}
}

showAlarms()
{
	curlgetauth "$TOKEN" "$AUTH_URL_CES/V1.0/$OS_PROJECT_ID/alarms/$1" | jq '.'
	return ${PIPESTATUS[0]}
}

showAlarmsQuotas()
{
	curlgetauth "$TOKEN" "$AUTH_URL_CES/V1.0/$OS_PROJECT_ID/quotas" | jq '.'
	return ${PIPESTATUS[0]}
}

deleteAlarms()
{
	curldeleteauth "$TOKEN" "$AUTH_URL_CES/V1.0/$OS_PROJECT_ID/alarms/$1" | jq '.'
	return ${PIPESTATUS[0]}
}

AlarmsAction()
{
	curlputauth "$TOKEN" "{ \"alarm_enabled\": $1 }" "$AUTH_URL_CES/V1.0/$OS_PROJECT_ID/alarms/$2/action"
	#return $?
}

listTrackers()
{
	curlgetauth "$TOKEN" "$AUTH_URL_CTS/v1.0/$OS_PROJECT_ID/tracker" | jq -r '.[] | .tracker_name+"   "+.bucket_name+"   "+.status+"   "+.file_prefix_name'
	return ${PIPESTATUS[0]}
}

### RLSH 2017-10-06 #########################################################
listTraces()
{
	SERVICE_TYPE=$1 ;
	case  $SERVICE_TYPE  in
		"IAM" )
			# echo "URL: " "$AUTH_URL_CTS/v1.0/$OS_PROJECT_ID/system/trace?service_type=$SERVICE_TYPE"
			LIST=$(curlgetauth "$TOKEN" "$AUTH_URL_CTS/v1.0/$OS_PROJECT_ID/system/trace?service_type=$SERVICE_TYPE" | \
				jq -r '.traces[] | [.time, .trace_name, .resource_name, .source_ip, .code]' | \
				sed 's/\(\[\|\]\|"\)//g' | \
				sed -e 's/^[ \t]*//' | \
				sed -z 's/,\n/\t/g' | \
				sed '/^$/d') ;
			echo -e "$LIST" ;
			# return ${PIPESTATUS[0]} ;
			;;
		"ECS" )
			LIST=$(curlgetauth "$TOKEN" "$AUTH_URL_CTS/v1.0/$OS_PROJECT_ID/system/trace?service_type=$SERVICE_TYPE&limit=199" | \
				jq -r '.traces[] | [.time, .request, .resource_name, .user, .source_ip, .message]' | \
				sed -r 's/(\\n(\\t)*|"|\{|\}|\\|\[|\])//g' | \
				sed -e 's/^[ \t]*//' | \
				sed 's/:\s*/:/g' | \
				sed 's/\s*,/,/g' | \
				sed -z 's/,\n/\t/g' |\
				sed '/^$/d' \
				) ;
			# echo -e "$LIST" ;
			### formatting stuff
			while read -r LINE;
			do
				array=(${LINE//,/}) ;
				arraylength=${#array[@]} ;
				for (( i=0; i<${arraylength}; i++ ));
				do
					if [ $i == 0 ];
					then
						printf "${array[$i]}" ;
					elif [ $i == 1 ];
					then
						ACTION=$(echo ${array[$i]} | awk -F':' '{printf $1}') ;
						printf "   $ACTION" ;
					elif [ $i == 3 ];
					then
						USER=$(echo ${array[$i]} | awk -F'id:' '{printf $1}' | awk -F':' '{printf $2}') ;
						printf "   $USER" ;
					else
						printf "   ${array[$i]}" ;
					fi
				done
				printf "\n" ;
			done <<< "$LIST"
			# return ${PIPESTATUS[0]} ;
			;;
		"CTS" )
			LIST=$(curlgetauth "$TOKEN" "$AUTH_URL_CTS/v1.0/$OS_PROJECT_ID/system/trace?service_type=$SERVICE_TYPE" | \
				jq '.traces[] | [.time, .trace_name, .resource_name, .user, .source_ip]' | \
				sed 's/\(\[\|\]\|"\|{\|}\|\\\)//g' | \
				sed -e 's/^[ \t]*//' | \
				sed -z 's/,\n/\t/g' | \
				sed '/^$/d') ;
			# echo -e "$LIST" ;
			### formatting stuff
			while read -r LINE;
			do
				array=(${LINE//,/}) ;
				arraylength=${#array[@]} ;
				for (( i=0; i<${arraylength}; i++ ));
				do
					if [ $i == 0 ];
					then
						printf "${array[$i]}" ;
					elif [ $i == 3 ];
					then
						USER=$(echo ${array[$i]} | awk -F'name:' '{printf $2}' | awk -F'domain:' '{printf $1}') ;
						printf "   $USER" ;
					else
						printf "   ${array[$i]}" ;
					fi
				done
				printf "\n" ;
			done <<< "$LIST"
			;;
		* )
			otcnewHelp ;
			exit 0 ;
	esac
}
#############################################################################

listQueues()
{
	#curlgetauth "$TOKEN" "$AUTH_URL_DMS/v1.0/$OS_PROJECT_ID/queues" | jq '.'
	curlgetauth "$TOKEN" "$AUTH_URL_DMS/v1.0/$OS_PROJECT_ID/queues" | jq -r 'def str(v): v|tostring; .queues[] | .id+"   "+.name+"   "+str(.produced_messages)+"   "+.description'
	return ${PIPESTATUS[0]}
}

showQueue()
{
	QID=$1
	if ! is_uuid "$1"; then QID=$(curlgetauth  "$TOKEN" "$AUTH_URL_DMS/v1.0/$OS_PROJECT_ID/queues" | find_id queues $1); fi
	curlgetauth "$TOKEN" "$AUTH_URL_DMS/v1.0/$OS_PROJECT_ID/queues/$QID" | jq -r '.'
	return ${PIPESTATUS[0]}
}

createQueue()
{
	if test -n "$1" -a -z "$NAME"; then NAME=$1; fi
	shift
	if test -z "$DESCRIPTION"; then
		if test -n "$1"; then DESCRIPTION="$@"; else
		DESCRIPTION="Message queue $NAME"; fi
	fi
	curlpostauth "$TOKEN" "{ \"name\": \"$NAME\", \"description\": \"$DESCRIPTION\" }" "$AUTH_URL_DMS/v1.0/$OS_PROJECT_ID/queues" | jq -r '.'
	return ${PIPESTATUS[0]}
}

deleteQueue()
{
	QID=$1
	if ! is_uuid "$1"; then QID=$(curlgetauth  "$TOKEN" "$AUTH_URL_DMS/v1.0/$OS_PROJECT_ID/queues" | find_id queues $1); fi
	curldeleteauth "$TOKEN" "$AUTH_URL_DMS/v1.0/$OS_PROJECT_ID/queues/$QID"
}

createConsumerGroup()
{
	QID=$1
	if ! is_uuid "$1"; then QID=$(curlgetauth  "$TOKEN" "$AUTH_URL_DMS/v1.0/$OS_PROJECT_ID/queues" | find_id queues $1); fi
	if test -z "$NAME" -a -n "$2"; then NAME="$2"; fi
	curlpostauth "$TOKEN" "{ \"groups\": [ { \"name\": \"$NAME\" } ] }" "$AUTH_URL_DMS/v1.0/$OS_PROJECT_ID/queues/$QID/groups" | jq -r '.'
	return ${PIPESTATUS[0]}
}

listConsumerGroups()
{
	QID=$1
	if ! is_uuid "$1"; then QID=$(curlgetauth  "$TOKEN" "$AUTH_URL_DMS/v1.0/$OS_PROJECT_ID/queues" | find_id queues $1); fi
	curlgetauth "$TOKEN" "$AUTH_URL_DMS/v1.0/$OS_PROJECT_ID/queues/$QID/groups" | jq -r 'def str(s): s|tostring; .groups[] | .id+"   "+.name+"   "+str(.consumed_messages)+"   "+str(.available_messages)+"   "+str(.produced_messages)'
	return ${PIPESTATUS[0]}
}

deleteConsumerGroup()
{
	QID=$1
	if ! is_uuid "$1"; then QID=$(curlgetauth  "$TOKEN" "$AUTH_URL_DMS/v1.0/$OS_PROJECT_ID/queues" | find_id queues $1); fi
	GID=$2
	if ! is_uuid "${GID#g-}"; then GID=$(curlgetauth  "$TOKEN" "$AUTH_URL_DMS/v1.0/$OS_PROJECT_ID/queues/$QID/groups" | find_id groups $2); fi
	curldeleteauth "$TOKEN" "$AUTH_URL_DMS/v1.0/$OS_PROJECT_ID/queues/$QID/groups/$GID"
}

cleanqmessage()
{
	#sed -re 's/\\/\\\\/g' -e 's/"/\\"/g'
	cat -
}

quoteval()
{
	# null or bool
	if test "$1" == "null" -o "$1" == "true" -o "$1" == false; then echo "$1"; return; fi
	# NUMBER
	echo "$@" | grep -q '^[0-9-][0-9.]*\([eE][+-]*[0-9]*\|\)'
	if test $? = 0; then echo "$@"; return; fi
	echo "\"$@\""
}

# Set KVIFS
# Build JSON dict from key=value list
buildkv()
{
	local VAL=""
	for arg in "$@"; do
		local VALS="$arg"
		while test -n "$VALS"; do
			IFS="$KVIFS" read this VALS < <(echo "$VALS")
			IFS="=" read key val < <(echo $this)
			VAL="$VAL, \"$key\": $(quoteval $val)"
		done
	done
	echo "{ ${VAL#, } }"
}

queueMessage()
{
	QID=$1; shift
	if ! is_uuid "$QID"; then QID=$(curlgetauth  "$TOKEN" "$AUTH_URL_DMS/v1.0/$OS_PROJECT_ID/queues" | find_id queues $QID); fi
	if test -z "$QID" -o "$QID" = "null"; then echo "ERROR: No such queue $QID" 1>&2; exit 3; fi
	local ATTR=""
	if test "$1" == "--attributes"; then ATTR=", \"attributes\": $2"; shift; shift; fi
	if test "$1" == "--attrkv"; then KVIFS=","; ATTR=", \"attributes\": $(buildkv $2)"; unset KVIFS; shift; shift; fi
	# Read message from stdin (or take cmdline as key=value list)
	unset KVIFS
	if test -n "$1"; then
		local MESG=$(buildkv "$@")
	else
		if tty >/dev/null; then echo "Enter your message, finish by ^D" 1>&2; fi
		MESG=$(cleanqmessage)
	fi
	curlpostauth "$TOKEN" "{ \"messages\": [ { \"body\": $MESG$ATTR } ] }" "$AUTH_URL_DMS/v1.0/$OS_PROJECT_ID/queues/$QID/messages"
}

ackMessage()
{
	QID=$1; shift
	if ! is_uuid "$QID"; then QID=$(curlgetauth  "$TOKEN" "$AUTH_URL_DMS/v1.0/$OS_PROJECT_ID/queues" | find_id queues $QID); fi
	if test -z "$QID" -o "$QID" = "null"; then echo "ERROR: No such queue $QID" 1>&2; exit 3; fi
	GID=$1; shift
	if ! is_uuid "${GID#g-}"; then GID=$(curlgetauth  "$TOKEN" "$AUTH_URL_DMS/v1.0/$OS_PROJECT_ID/queues/$QID/groups" | find_id groups $GID); fi
	if test -z "$GID" -o "$GID" = "null"; then echo "ERROR: No such consumer group $GID" 1>&2; exit 3; fi
	SUCCESS="success"
	if test "$1" == "--fail"; then SUCCESS="fail"; shift; fi
	HANDLES=""
	for hand in "$@"; do
		HANDLES="$HANDLES, { \"handler\": \"$hand\", \"status\": \"$SUCCESS\" }"
	done
	HANDLES="${HANDLES#, }"
	curlpostauth "$TOKEN" "{ \"message\": [ $HANDLES ] }" "$AUTH_URL_DMS/v1.0/$OS_PROJECT_ID/queues/$QID/groups/$GID/ack" | jq -r '.'
	return ${PIPESTATUS[0]}
}

getMessage()
{
	if test "$1" = "--ack"; then DOACK=1; shift; fi
	if test "$1" = "--maxmsg"; then MAXMSG=$2; shift; shift; fi
	if test "$1" = "--kv"; then DOKV=1; shift; fi
	QID=$1
	if ! is_uuid "$QID"; then QID=$(curlgetauth  "$TOKEN" "$AUTH_URL_DMS/v1.0/$OS_PROJECT_ID/queues" | find_id queues $1); fi
	if test -z "$QID" -o "$QID" = "null"; then echo "ERROR: No such queue $1" 1>&2; exit 3; fi
	shift; GID=$1
	if ! is_uuid "${GID#g-}"; then GID=$(curlgetauth  "$TOKEN" "$AUTH_URL_DMS/v1.0/$OS_PROJECT_ID/queues/$QID/groups" | find_id groups $GID); fi
	if test -z "$GID" -o "$GID" = "null"; then echo "ERROR: No such consumer group $1" 1>&2; exit 3; fi
	shift; MAXMSG=1
	if test "$1" = "--ack"; then DOACK=1; shift; fi
	if test "$1" = "--kv"; then DOKV=1; shift; fi
	if test "$1" = "--maxmsg"; then MAXMSG=$2; shift; shift; fi
	if test "$1" = "--kv"; then DOKV=1; shift; fi
	#if test "$1" = "--wait"; then WAIT=$2; shift; shift; fi
	INDMS=1
	MSG=$(curlgetauth "$TOKEN" "$AUTH_URL_DMS/v1.0/$OS_PROJECT_ID/queues/$QID/groups/$GID/messages?max_msgs=$MAXMSG")
	RC=$?
	HANDLES=$(echo "$MSG" | jq -r '.[].handler')
	if test "$DOKV" = "1"; then
		echo "HANDLES=($HANDLES)"
		declare -i ctr=0
		for hand in $HANDLES; do
			local smsg=$(echo "$MSG" | jq -r ".[] | select(.handler == \"$hand\")")
			echo $smsg | jq -r '.message.body' | sed "s@^ *\"\([^\"]*\)\": \(\"[^\"]*\"\|[^,]*\)\(,\|\)\$@\1[$ctr]=\2@" | grep -v '^{$' | grep -v '^}$'
			#echo "BODY[$ctr]=$(echo $smsg | jq -r '.message.body')"
			echo $smsg | jq -r '.message.attributes' | sed "s@^ *\"\([^\"]*\)\": \(\"[^\"]*\"\|[^,]*\)\(,\|\)\$@ATTR_\1[$ctr]=\2@" | grep -v '^{$' | grep -v '^}$' | grep -v '^null$'
			let ctr+=1
		done
	else
		echo "$MSG" | jq -r '.'
	fi
	if test "$DOACK" = "1"; then ackMessage $QID $GID $HANDLES; fi
	return $RC
}

queueLimits()
{
	curlgetauth "$TOKEN" "$AUTH_URL_DMS/v1.0/$OS_PROJECT_ID/quotas/dms" | jq -r '.'
	return ${PIPESTATUS[0]}
}

listTopics()
{
	#curlgetauth "$TOKEN" "$AUTH_URL_SMN/v2/$OS_PROJECT_ID/notifications/topics?offset=0&limit=100" | jq '.'
	setlimit 100 "offset=0"
	curlgetauth "$TOKEN" "$AUTH_URL_SMN/v2/$OS_PROJECT_ID/notifications/topics$PARAMSTRING" | jq -r '.topics[] | .topic_urn+"   "+.name+"   "+.display_name'
	return ${PIPESTATUS[0]}
}

showTopic()
{
	curlgetauth "$TOKEN" "$AUTH_URL_SMN/v2/$OS_PROJECT_ID/notifications/topics/$1" | jq -r '.'
	return ${PIPESTATUS[0]}
}

createTopic()
{
	if test -n "$2"; then local DISPLAYNM=", \"display_name\": \"$2\""; fi
	curlpostauth "$TOKEN" "{ \"name\": \"$1\" $DISPLAYNM }" "$AUTH_URL_SMN/v2/$OS_PROJECT_ID/notifications/topics" | jq -r '.'
	return ${PIPESTATUS[0]}
}

deleteTopic()
{
	curldeleteauth "$TOKEN" "$AUTH_URL_SMN/v2/$OS_PROJECT_ID/notifications/topics/$1" | jq -r '.'
	return ${PIPESTATUS[0]}
}

cleansmnmessage()
{
	tr -d '\r' | tr '\n' '\r' | sed -re 's/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K]//g' -e 's/\x1B/\\e/g' -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\n/g'
}

publishNotification()
{
	local TOPIC_URN="$1"; shift
	if test -n "$1"; then local SUBJECT="\"subject\": \"$1\","; shift; fi
	# Read message from stdin (or take cmdline)
	if test -n "$1"; then local MESG=$(echo "$@" | cleansmnmessage)
	else
		if tty >/dev/null; then echo "Enter your message, finish by ^D" 1>&2; fi
		local MESG=$(cleansmnmessage)
	fi
	curlpostauth "$TOKEN" "{ $SUBJECT \"message\": \"$MESG\" }" "$AUTH_URL_SMN/v2/$OS_PROJECT_ID/notifications/topics/$TOPIC_URN/publish" | jq -r '.'
	return ${PIPESTATUS[0]}
}

listSubscriptions()
{
	#curlgetauth "$TOKEN" "$AUTH_URL_SMN/v2/$OS_PROJECT_ID/notifications/topics?offset=0&limit=100" | jq '.'
	setlimit 100 "offset=0"
	curlgetauth "$TOKEN" "$AUTH_URL_SMN/v2/$OS_PROJECT_ID/notifications/subscriptions$PARAMSTRING" | jq -r 'def stat(s): ["unconfirmed", "confirmed", "?", "canceled"][s]; .subscriptions[] | .subscription_urn+"   "+.topic_urn+"   "+stat(.status)+"   "+.protocol+"   "+.endpoint+"   "+.remark'
	return ${PIPESTATUS[0]}
}

addSubscription()
{
	local REMARK=""
	if test -n "$4"; then REMARK=", \"remark\": \"$4\""; fi
	curlpostauth "$TOKEN" "{ \"protocol\": \"$2\", \"endpoint\": \"$3\" $REMARK }" "$AUTH_URL_SMN/v2/$OS_PROJECT_ID/notifications/topics/$1/subscriptions" | jq -r '.'
	return ${PIPESTATUS[0]}
}

deleteSubscription()
{
	curldeleteauth "$TOKEN" "$AUTH_URL_SMN/v2/$OS_PROJECT_ID/notifications/subscriptions/$1" | jq -r '.'
	return ${PIPESTATUS[0]}
}

sendSMS()
{
	local EP=$1; shift
	local MESG=$(echo "$@" | cleansmnmessage)
	curlpostauth "$TOKEN" "{ \"endpoint\": \"$EP\", \"message\": \"$MESG\" }" "$AUTH_URL_SMN/v2/$OS_PROJECT_ID/notifications/sms" | jq -r '.'
	return ${PIPESTATUS[0]}
}


createPROJECT()
{
	local NAME="$1"; shift
	local DESC
	REG="${OS_REGION_NAME}_"
	REGLN=${#REG}
	if test "${NAME:0:$REGLN}" != "$REG"; then echo "WARN: Project creation: Start name with $REG" 1>&2; fi
	if test -z "$DESCRIPTION" -a -n "$2"; then DESCRIPTION="$*"; fi
	if test -n "$DESCRIPTION"; then DESC=", \"description\": \"$DESCRIPTION\""; fi
	curlpostauth "$TOKEN" "{ \"project\": { \"name\": \"$NAME\"$DESC } }" "${IAM_AUTH_URL%/auth*}/projects" | jq -r '.'
	return ${PIPESTATUS[0]}
}

deletePROJECT()
{
	local ID="$1"
	if ! is_id "$ID"; then ID=`curlgetauth "$TOKEN" "${IAM_AUTH_URL%/auth*}/projects?name=$ID" | jq '.projects[].id' | tr -d '"'`; fi
	curldeleteauth "$TOKEN" "${IAM_AUTH_URL%/auth*}/projects/$ID" | jq -r '.'
	return ${PIPESTATUS[0]}
}

deletePROJECText()
{
	local ID="$1"
	if ! is_id "$ID"; then ID=`curlgetauth "$TOKEN" "${IAM_AUTH_URL%/auth*}/projects?name=$ID" | jq '.projects[].id' | tr -d '"'`; fi
	#curldeleteauth "$TOKEN" "${IAM_AUTH_URL%/auth*}-ext/projects/$ID"
	curlputauth "$TOKEN" "{ \"project\": { \"status\": \"suspended\" } }" "${IAM_AUTH_URL%/auth*}-ext/projects/$ID"
	#return ${PIPESTATUS[0]}
}

recoverPROJECText()
{
	local ID="$1"
	if ! is_id "$ID"; then ID=`curlgetauth "$TOKEN" "${IAM_AUTH_URL%/auth*}/projects?name=$ID" | jq '.projects[].id' | tr -d '"'`; fi
	curlputauth "$TOKEN" "{ \"project\": { \"status\": \"normal\" } }" "${IAM_AUTH_URL%/auth*}-ext/projects/$ID"
}

# User Management
# Parser for user mgmt params
parseUserParm()
{
	unset NONOPTARG PWDJSON NAMEJSON DESCJSON PRJJSON ENJSON
	while test -n "$1"; do
		case "$1" in
			--password|--passwd)
				PWDJSON="\"password\": \"$2\","
				shift; shift ;;
			--name|--user|--username)
				NAMEJSON="\"name\": \"$2\","
				shift; shift ;;
			--description|--desc)
				DESCJSON="\"description\": \"$2\","
				shift; shift ;;
			--default-project|--default-prj|--defaultproject|--defaultprj)
				PRJJSON="\"default_project_id\": \"$2\","
				shift; shift ;;
			--disabled|--disable)
				ENJSON="\"enabled\": false,"
				shift ;;
			--enabled|--enable)
				ENJSON="\"enabled\": true,"
				shift ;;
			--*)
				echo "Unsupported parameter $1" 1>&2
				exit 1 ;;
			*)
				NONOPTARG="$1"
				shift ;;
		esac
	done
}

addUser()
{
	parseUserParm "$@"
	if test -z "$NAMEJSON" -a -n "$NONOPTARG"; then NAMEJSON="\"name\": \"$NONOPTARG\","; fi
	if test -z "$ENJSON"; then ENJSON="\"enabled\": true,"; fi
	if test -z "$NAMEJSON"; then echo "Must specify --name" 1>&2; exit 1; fi
	curlpostauth "$TOKEN" "{
		\"user\": {
			$PRJJSON
			$ENJSON
			$NAMEJSON
			$DESCJSON
			${PWDJSON%,}
		}
	}" "${IAM_AUTH_URL%/auth*}/users" | jq -r '.'
	return ${PIPESTATUS[0]}
}

changeUser()
{
	parseUserParm "$@"
	local USID="$(uriencode $NONOPTARG)"
	if test -z "$USID"; then echo "Need to specify UserID or UserName" 1>&2; exit 1; fi
	if ! is_id $USID; then USID=$(curlgetauth $TOKEN ${IAM_AUTH_URL%/auth*}/users?name=$USID | jq '.users[].id' | tr -d '"'); fi
	if test -z "$USID"; then echo "No such user $1" 1>&2; exit 2; fi
	local JSON=$(rmvCommaJSON "{
		\"user\": {
			$PRJJSON
			$ENJSON
			$NAMEJSON
			$DESCJSON
			${PWDJSON%,}
		}
	}")
	curlpatchauth $TOKEN "$JSON" "${IAM_AUTH_URL%/auth*}/users/$USID" | jq -r '.'
	return ${PIPESTATUS[0]}
}

showUser()
{
	local USID="$(uriencode $1)"
	if ! is_id $USID; then USID=$(curlgetauth $TOKEN ${IAM_AUTH_URL%/auth*}/users?name=$USID | jq '.users[].id' | tr -d '"'); fi
	if test -z "$USID"; then echo "No such user $1" 1>&2; exit 2; fi
	curlgetauth $TOKEN ${IAM_AUTH_URL%/auth*}/users/$USID | jq -r '.'
	return ${PIPESTATUS[0]}
}

delUser()
{
	local USID="$(uriencode $1)"
	if ! is_id $USID; then USID=$(curlgetauth $TOKEN ${IAM_AUTH_URL%/auth*}/users?name=$USID | jq '.users[].id' | tr -d '"'); fi
	if test -z "$USID"; then echo "No such user $1" 1>&2; exit 2; fi
	curldeleteauth $TOKEN ${IAM_AUTH_URL%/auth*}/users/$USID
}

# Groups
# Parser for group mgmt params
parseGroupParm()
{
	unset NONOPTARG NAMEJSON DESCJSON DOMJSON
	while test -n "$1"; do
		case "$1" in
			--name|--group)
				NAMEJSON="\"name\": \"$2\","
				shift; shift ;;
			--description|--desc)
				DESCJSON="\"description\": \"$2\","
				shift; shift ;;
			--domain-id|domainid)
				DOMJSON="\"domain_id\": \"$2\","
				shift; shift ;;
			--*)
				echo "Unsupported parameter $1" 1>&2
				exit 1 ;;
			*)
				NONOPTARG="$1"
				shift ;;
		esac
	done
}

addGroup()
{
	parseGroupParm "$@"
	if test -z "$NAMEJSON" -a -n "$NONOPTARG"; then NAMEJSON="\"name\": \"$NONOPTARG\","; fi
	if test -z "$NAMEJSON"; then echo "Must specify --name" 1>&2; exit 1; fi
	curlpostauth "$TOKEN" "{
		\"group\": {
			$DOMJSON
			$DESCJSON
			${NAMEJSON%,}
		}
	}" "${IAM_AUTH_URL%/auth*}/groups" | jq -r '.'
	return ${PIPESTATUS[0]}
}

changeGroup()
{
	parseGroupParm "$@"
	local GRID="$(uriencode $NONOPTARG)"
	if test -z "$GRID"; then echo "Need to specify GroupID or GroupName" 1>&2; exit 1; fi
	if ! is_id $GRID; then GRID=$(curlgetauth $TOKEN ${IAM_AUTH_URL%/auth*}/groups?name=$GRID | jq '.groups[].id' | tr -d '"'); fi
	if test -z "$GRID"; then echo "No such group" 1>&2; exit 2; fi
	local JSON=$(rmvCommaJSON "{
		\"group\": {
			$DOMJSON
			$DESCJSON
			${NAMEJSON%,}
		}
	}")
	curlpatchauth $TOKEN "$JSON" "${IAM_AUTH_URL%/auth*}/groups/$GRID" | jq -r '.'
	return ${PIPESTATUS[0]}
}

showGroup()
{
	local GRID="$(uriencode $1)"
	if test -z "$GRID"; then echo "Need to specify GroupID or GroupName" 1>&2; exit 1; fi
	if ! is_id $GRID; then GRID=$(curlgetauth $TOKEN ${IAM_AUTH_URL%/auth*}/groups?name=$GRID | jq '.groups[].id' | tr -d '"'); fi
	if test -z "$GRID"; then echo "No such group $1" 1>&2; exit 2; fi
	curlgetauth $TOKEN ${IAM_AUTH_URL%/auth*}/groups/$GRID | jq -r '.'
	return ${PIPESTATUS[0]}
}

listGroup()
{
	local GRID="$(uriencode $1)"
	if test -z "$GRID"; then echo "Need to specify GroupID or GroupName" 1>&2; exit 1; fi
	if ! is_id $GRID; then GRID=$(curlgetauth $TOKEN ${IAM_AUTH_URL%/auth*}/groups?name=$GRID | jq '.groups[].id' | tr -d '"'); fi
	if test -z "$GRID"; then echo "No such group $1" 1>&2; exit 2; fi
	curlgetauth $TOKEN ${IAM_AUTH_URL%/auth*}/groups/$GRID/users | jq -r 'def enstr(v): v|tostring; .users[] | .id+"   "+.name+"   "+enstr(.enabled)+"   "+.description' | tr -d '"'
	return ${PIPESTATUS[0]}
}

checkGroup()
{
	local GRID="$(uriencode $1)"
	if test -z "$GRID"; then echo "Need to specify GroupID or GroupName" 1>&2; exit 1; fi
	if ! is_id $GRID; then GRID=$(curlgetauth $TOKEN ${IAM_AUTH_URL%/auth*}/groups?name=$GRID | jq '.groups[].id' | tr -d '"'); fi
	if test -z "$GRID"; then echo "No such group $1" 1>&2; exit 2; fi
	local USID="$(uriencode $2)"
	if ! is_id $USID; then USID=$(curlgetauth $TOKEN ${IAM_AUTH_URL%/auth*}/users?name=$USID | jq '.users[].id' | tr -d '"'); fi
	if test -z "$USID"; then echo "No such user $2" 1>&2; exit 2; fi
	HDR=$(curlheadauth $TOKEN ${IAM_AUTH_URL%/auth*}/groups/$GRID/users/$USID)
}

delGroup()
{
	local GRID="$1"
	if test -z "$GRID"; then echo "Need to specify GroupID or GroupName" 1>&2; exit 1; fi
	if ! is_id $GRID; then GRID=$(curlgetauth $TOKEN ${IAM_AUTH_URL%/auth*}/groups?name=$GRID | jq '.groups[].id' | tr -d '"'); fi
	if test -z "$GRID"; then echo "No such group $1" 1>&2; exit 2; fi
	curldeleteauth $TOKEN ${IAM_AUTH_URL%/auth*}/groups/$GRID
}

addGroupUser()
{
	local GRID="$(uriencode $1)"
	if test -z "$GRID"; then echo "Need to specify GroupID or GroupName" 1>&2; exit 1; fi
	if ! is_id $GRID; then GRID=$(curlgetauth $TOKEN ${IAM_AUTH_URL%/auth*}/groups?name=$GRID | jq '.groups[].id' | tr -d '"'); fi
	if test -z "$GRID"; then echo "No such group $1" 1>&2; exit 2; fi
	local USID="$(uriencode $2)"
	if ! is_id $USID; then USID=$(curlgetauth $TOKEN ${IAM_AUTH_URL%/auth*}/users?name=$USID | jq '.users[].id' | tr -d '"'); fi
	if test -z "$USID"; then echo "No such user $2" 1>&2; exit 2; fi
	curlputauth $TOKEN "" ${IAM_AUTH_URL%/auth*}/groups/$GRID/users/$USID
}

delGroupUser()
{
	local GRID="$(uriencode $1)"
	if test -z "$GRID"; then echo "Need to specify GroupID or GroupName" 1>&2; exit 1; fi
	if ! is_id $GRID; then GRID=$(curlgetauth $TOKEN ${IAM_AUTH_URL%/auth*}/groups?name=$GRID | jq '.groups[].id' | tr -d '"'); fi
	if test -z "$GRID"; then echo "No such group $1" 1>&2; exit 2; fi
	local USID="$(uriencode $2)"
	if ! is_id $USID; then USID=$(curlgetauth $TOKEN ${IAM_AUTH_URL%/auth*}/users?name=$USID | jq '.users[].id' | tr -d '"'); fi
	if test -z "$USID"; then echo "No such user $2" 1>&2; exit 2; fi
	curldeleteauth $TOKEN ${IAM_AUTH_URL%/auth*}/groups/$GRID/users/$USID
}

# Roles
ROLEDISPLAY='def tostr(v): v|tostring; .roles[] | .id+"   "+.name+"   "+.catalog+"   "+.display_name+"   "+.type+"   "+tostr(.policy.Statement)+"   "+tostr(.policy.Depends)'
listRoleAssign()
{
	local USID="$(uriencode $1)"
	if ! is_id $USID; then USID=$(curlgetauth $TOKEN ${IAM_AUTH_URL%/auth*}/users?name=$USID | jq '.users[].id' | tr -d '"'); fi
	if test -z "$USID"; then echo "No such user $1" 1>&2; exit 2; fi
	if test "$2" == "--effective"; then EFF="&effective"; fi
	curlgetauth $TOKEN "${IAM_AUTH_URL%/auth*}/role_assignmentsr?user.id=$USID&include_names$EFF" | jq "$ROLEDISPLAY" | tr -d '"'
}

listRoleUser()
{
	local SCP=domain
	local SCPID=$OS_USER_DOMAIN_ID
	if test "$1" == "listrolegroup"; then OBJ=group; else OBJ=user; fi; shift
	if test "$1" == "--project"; then SCP=project; SCPID=$2; shift; shift; fi
	local USID="$(uriencode $1)"
	if ! is_id $USID; then USID=$(curlgetauth $TOKEN ${IAM_AUTH_URL%/auth*}/${OBJ}s?name=$USID | jq ".${OBJ}s[].id" | tr -d '"'); fi
	if test -z "$USID"; then echo "No such $OBJ $1" 1>&2; exit 2; fi
	if test "$2" == "--project"; then SCP=project; SCPID=$3; fi
	curlgetauth $TOKEN "${IAM_AUTH_URL%/auth*}/${SCP}s/$SCPID/${OBJ}s/$USID/roles" | jq "$ROLEDISPLAY" | tr -d '"'
	return ${PIPESTATUS[0]}
}

addRoleUser()
{
	local SCP=domain
	local SCPID=$OS_USER_DOMAIN_ID
	if test "$1" == "addrolegroup"; then OBJ=group; else OBJ=user; fi; shift
	if test "$1" == "--project"; then SCP=project; SCPID=$2; shift; shift; fi
	local RID="$(uriencode $1)"
	if ! is_id $RID; then RID=$(curlgetauth $TOKEN ${IAM_AUTH_URL%/auth*}/roles?name=$RID | jq '.roles[].id' | tr -d '"'); fi
	if test -z "$RID"; then echo "Need to specify valid role" 1>&2; exit 2; fi
	local USID="$(uriencode $2)"
	if ! is_id $USID; then USID=$(curlgetauth $TOKEN ${IAM_AUTH_URL%/auth*}/${OBJ}s?name=$USID | jq ".${OBJ}s[].id" | tr -d '"'); fi
	if test -z "$USID"; then echo "No such $OBJ $2" 1>&2; exit 2; fi
	if test "$3" == "--project"; then SCP=project; SCPID=$4; fi
	curlputauth $TOKEN "" "${IAM_AUTH_URL%/auth*}/${SCP}s/$SCPID/${OBJ}s/$USID/roles/$RID"
}

delRoleUser()
{
	local SCP=domain
	local SCPID=$OS_USER_DOMAIN_ID
	if test "$1" == "delrolegroup" -o "$1" == "deleterolegroup"; then OBJ=group; else OBJ=user; fi; shift
	if test "$1" == "--project"; then SCP=project; SCPID=$OS_PROJECT_ID; shift; fi
	local RID="$(uriencode $1)"
	if ! is_id $RID; then RID=$(curlgetauth $TOKEN ${IAM_AUTH_URL%/auth*}/roles?name=$RID | jq '.roles[].id' | tr -d '"'); fi
	if test -z "$RID"; then echo "Need to specify valid role" 1>&2; exit 2; fi
	local USID="$(uriencode $2)"
	if ! is_id $USID; then USID=$(curlgetauth $TOKEN ${IAM_AUTH_URL%/auth*}/${OBJ}s?name=$USID | jq ".${OBJ}s[].id" | tr -d '"'); fi
	if test -z "$USID"; then echo "No such $OBJ $2" 1>&2; exit 2; fi
	if test "$3" == "--project"; then SCP=project; SCPID=$4; shift; fi
	curldeleteauth $TOKEN "${IAM_AUTH_URL%/auth*}/${SCP}s/$SCPID/${OBJ}s/$USID/roles/$RID"
}

# These don't work yet well
listMRSClusters()
{
	curlgetauth "$TOKEN" "$AUTH_URL_MRS/v1.1/$OS_PROJECT_ID/cluster-infos" | jq -r '.'
	return ${PIPESTATUS[0]}
}

listMRSJobs()
{
	curlgetauth "$TOKEN" "$AUTH_URL_MRS/v1.1/$OS_PROJECT_ID/jobs-exes" | jq -r '.'
	return ${PIPESTATUS[0]}
}

showMRSJob()
{
	curlgetauth "$TOKEN" "$AUTH_URL_MRS/v1.1/$OS_PROJECT_ID/jobs-exes/$1" | jq -r '.'
	return ${PIPESTATUS[0]}
}

listAntiDDoS()
{
	echo "#Traffic limited list: POS Mbps PPS"
	RESP=$(curlgetauth "$TOKEN" "$AUTH_URL_ANTIDDOS/v1/$OS_PROJECT_ID/antiddos/query_config_list")
	RC=$RET
	echo "$RESP" | jq 'def str(v): v | tostring; .traffic_limited_list[] | str(.traffic_pos_id)+"   "+str(.traffic_per_second)+"   "+str(.packet_per_second)' | tr -d '"'
	echo "#HTTP limited list: POS PPS"
	echo "$RESP" | jq 'def str(v): v | tostring; .http_limited_list[] | str(.http_request_pos_id)+"   "+"   "+str(.http_packet_per_second)' | tr -d '"'
	echo "#Connection limited list: POS Conn/s TotConn"
	echo "$RESP" | jq 'def str(v): v | tostring; .connection_limited_list[] | str(.cleaning_access_pos_id)+"   "+str(.new_connection_limited)+"   "+str(.total_connection_limited)' | tr -d '"'
	echo "#Extend DDOS config: setID MBps PPS HTTPpS ConnpS TotConn"
	echo "$RESP" | jq 'def str(v): v | tostring; .extend_ddos_config[] | str(.setID)+"   "+str(.traffic_per_second)+"   "+str(.packet_per_second)+"   "+str(.http_packet_per_second)+"   "+str(.new_connection_limited)+"   "+str(.total_connection_limited)' | tr -d '"'
	return $RC
}

listKMS()
{
	# TODO: Translate into list format
	# POST, bad API design
	curlpostauth "$TOKEN" "" "$AUTH_URL_KMS/v1.0/$OS_PROJECT_ID/kms/list-keys" | jq -r '.'
	return ${PIPESTATUS[0]}
}

# Unsupported
listDirectConnects()
{
	# TODO: Translate into list format
	curlgetauth $TOKEN "$AUTH_URL_DCAAS/direct-connects" | jq -r '.'
}

listMigrations()
{
	# TODO: Translate into list format
	curlgetauth $TOKEN "$AUTH_URL_MAAS/objectstorage/task?start=0&limit=100" | jq -r '.'
	#curlgetauth $TOKEN "$AUTH_URL_MAAS/objectstorage/task" | jq -r '.'
}

listShares()
{
	#curlgetauth $TOKEN "$AUTH_URL_SFS/shares" | jq -r '.shares[] | .id+"   "+.name'
	curlgetauth $TOKEN "$AUTH_URL_SFS/shares/detail" | jq -r 'def str(s): s|tostring; .shares[] | .id+"   "+.name+"   "+.status+"   "+.availability_zone+"   "+.share_proto+"   "+str(.size)+"   "+.export_location'
}

showShare()
{
	ID="$(uriencode $1)"
	if ! is_uuid "$1"; then ID=$(curlgetauth $TOKEN "$AUTH_URL_SFS/shares?name=$ID" | jq '.shares[].id' | head -n1 | tr -d '"'); else ID=$1; fi
	curlgetauth $TOKEN "$AUTH_URL_SFS/shares/$ID" | jq -r '.'
}

createTags()
{
	local KEYJSON=$(keyval2keyvalue "$@")
	curlpostauth $TOKEN "{ \"action\": \"create\", \"tags\": [ $KEYJSON ] }" "$AUTH_URL_TMS/predefine_tags/action"
}

deleteTags()
{
	local KEYJSON=$(keyval2keyvalue "$@")
	curlpostauth $TOKEN "{ \"action\": \"delete\", \"tags\": [ $KEYJSON ] }" "$AUTH_URL_TMS/predefine_tags/action"
}

listTags()
{
	# TODO: Translate into list format
	curlgetauth $TOKEN "$AUTH_URL_TMS/predefine_tags" | jq -r '.tags[] | .key+"="+.value+"   ("+.update_time+")"'
}

listCaches()
{
	# TODO: Translate into list format
	curlgetauth $TOKEN "$AUTH_URL_DCS/instances" | jq -r '.'
}

listCacheProducts()
{
	# TODO: Translate into list format
	curlgetauth $TOKEN "${AUTH_URL_DCS%/*}/products" | jq -r '.'
}

listCacheAZs()
{
	# TODO: Translate into list format
	curlgetauth $TOKEN "${AUTH_URL_DCS%/*}/availableZones" | jq -r '.'
}

listDWS()
{
	# TODO: Translate into list format
	curlgetauth $TOKEN "$AUTH_URL_DWS/clusters" | jq -r '.'
}

listServerBackups()
{
	# TODO: Translate into list format
	curlgetauth $TOKEN "$AUTH_URL_CSBS/checkpoint_items" | jq -r '.'
}

listVPN()
{
	curlgetauth $TOKEN "$NEUTRON_URL/v2.0/vpn/ipsec-site-connections" | jq '.ipsec_site_connections[] | .id+"   "+.name+"   "+.status+"   "+.auth_mode+"   "+.route_mode+"   "+.peer_address+"   "+.ikepolicy_id+"   "+.ipsecpolicy_id' | tr -d '"'
	return ${PIPESTATUS[0]}
}

listFWRules()
{
	curlgetauth $TOKEN "$NEUTRON_URL/v2.0/fwaas/firewall_rules" | jq -r '.'
	return ${PIPESTATUS[0]}
}

listDEH()
{
	curlgetauth $TOKEN "$AUTH_URL_DEH/v1.0/$OS_PROJECT_ID/dedicated-hosts" | jq 'def tostr(x): x|tostring; .dedicated_hosts[] | .dedicated_host_id+"   "+.name+"   "+.state+"   "+tostr(.instance_total)+"   "+.auto_placement+"   "+.availability_zone+"   "+.host_properties.host_type+"   "+tostr(.available_vcpus)+"   "+tostr(.available_memory)' | tr -d '"'
	return ${PIPESTATUS[0]}
}

showDEH()
{
	DEH="$(uriencode $1)"
	if ! is_uuid $1; then DEH=$(curlgetauth $TOKEN "$AUTH_URL_DEH/v1.0/$OS_PROJECT_ID/dedicated-hosts?name=$DEH" | jq '.dedicated_hosts[].dedicated_host_id' | tr -d '"'); fi
	curlgetauth $TOKEN "$AUTH_URL_DEH/v1.0/$OS_PROJECT_ID/dedicated-hosts/$DEH" | jq -r '.'
	return ${PIPESTATUS[0]}
}

listDEHservers()
{
	DEH="$(uriencode $1)"
	if ! is_uuid $1; then DEH=$(curlgetauth $TOKEN "$AUTH_URL_DEH/v1.0/$OS_PROJECT_ID/dedicated-hosts?name=$DEH" | jq '.dedicated_hosts[].dedicated_host_id' | tr -d '"'); fi
	curlgetauth $TOKEN "$AUTH_URL_DEH/v1.0/$OS_PROJECT_ID/dedicated-hosts/$DEH/servers" | jq '.servers[] | .id+"   "+.name+"   "+.status+"   "+.flavor.id' | tr -d '"'
	return ${PIPESTATUS[0]}
}

createDEH()
{
	NAME="$1"; shift
	TYPE="$1"; shift
	QUANT="$1"; shift
	if test -z "$AZ" -a -n "$1"; then AZ="$1"; shift; fi
	RST="$@"
	if test -z "$AUTOPLC" -a "${RST:0:1}" = "o"; then AUTOPLC="$RST"; shift; fi
	local APLACE
	if test -n "$AUTOPLC"; then APLACE=", \"auto_placement\": \"$AUTOPLC\""; fi
	curlpostauth $TOKEN "{ \"name\": \"$NAME\", \"availability_zone\": \"$AZ\", \"host_type\": \"$TYPE\", \"quantity\": $QUANT$APLACE }" "$AUTH_URL_DEH/v1.0/$OS_PROJECT_ID/dedicated-hosts" | jq -r '.'
	return ${PIPESTATUS[0]}
}

deleteDEH()
{
	DEH="$(uriencode $1)"
	if ! is_uuid $1; then DEH=$(curlgetauth $TOKEN "$AUTH_URL_DEH/v1.0/$OS_PROJECT_ID/dedicated-hosts?name=$DEH" | jq '.dedicated_hosts[].dedicated_host_id' | tr -d '"'); fi
	curldeleteauth $TOKEN "$AUTH_URL_DEH/v1.0/$OS_PROJECT_ID/dedicated-hosts/$DEH"
}

# Not yet implemented: updateDEH

listDEHtypes()
{
	curlgetauth $TOKEN "$AUTH_URL_DEH/v1.0/$OS_PROJECT_ID/availability-zone/$1/dedicated-host-types" | jq '.dedicated_host_types[] | .host_type+"   "+.host_type_name' | tr -d '"'
	return ${PIPESTATUS[0]}
}

# 3.0
listNATGW()
{
	curlgetauth $TOKEN "$AUTH_URL_NAT/nat_gateways" | jq '.'
}

listNATRules()
{
	curlgetauth $TOKEN "$AUTH_URL_NAT/snat_rules" | jq '.'
}

listDCAASConn()
{
	curlgetauth $TOKEN "$AUTH_URL_DCAAS/direct-connects" | jq '.'
}

listDCAASVGW()
{
	curlgetauth $TOKEN "$AUTH_URL_DCAAS/virtual-gateways" | jq '.'
}

listDCAASVIF()
{
	curlgetauth $TOKEN "$AUTH_URL_DCAAS/virtual-interfaces" | jq '.'
}

listDCAASEPGrp()
{
	curlgetauth $TOKEN "$AUTH_URL_DCAAS/dc-endpoint-groups" | jq '.'
}

listDIS()
{
	curlgetauth $TOKEN "$AUTH_URL_DIS/streams" | jq '.'
}

listProductCats()
{
	curlgetauth $TOKEN "$AUTH_URL_MKT/products/categories" | jq '.'
}


getMeta()
{
	local RESP DATA=$1; shift
	local FILT="."
	if test -n "$1"; then FILT="$@"; fi
	if test ${DATA%.json} != $DATA; then PROCESS="jq $FILT"; else
		if test "$FILT" != "."; then PROCESS="grep $FILT"; else PROCESS="cat -"; fi
	fi
	RESP=$(docurl -sS "http://169.254.169.254/openstack/latest/$DATA")
	RC=$?
	echo "$RESP" | grep -q "404 Not Found" >/dev/null 2>&1
	if test $? != 0 -o "$DATA" != "user_data"; then
		echo "$RESP" | $PROCESS
	fi
	return $RC
}

queryWorkspace()
{
	URL="$AUTH_URL_WORKSPACES"

	curlgetauth $TOKEN "$URL" | jq -r '.ad_domains.domain_type + "   " + .ad_domains.domain_name + "   " + .status + "   " + .access_mode + "   " + .internet_access_address' | sed -r '/^\s*$/d'

	return ${PIPESTATUS[0]}
}

applyWorkspace_getLiteAD()
{
	REQ_CREATE_WORKSPACE="
	{
		\"ad_domains\": {
			\"domain_type\": \"$DOMAINTYPE\",
			\"domain_name\": \"$DOMAINNAME\",
			\"domain_admin_account\": \"$DOMAINADMINACCOUNT\",
			\"domain_password\": \"$DOMAINADMINPASSWORD\"
		},
		\"vpc_id\": \"$VPCID\",
		\"subnet_ids\": [
			{
				\"subnet_id\": \"$SUBNETID\"
			}
		],
		\"access_mode\": \"$ACCESSMODE\",
		\"availablity_zone\": \"$AZ\"
	}"

	export REQ_CREATE_WORKSPACE
}

applyWorkspace_getLocalAD()
{
	REQ_CREATE_WORKSPACE="
	{
		\"ad_domains\": {
			\"domain_type\": \"$DOMAINTYPE\",
			\"domain_name\": \"$DOMAINNAME\",
			\"domain_admin_account\": \"$DOMAINADMINACCOUNT\",
			\"domain_password\": \"$DOMAINADMINPASSWORD\",
			\"active_domain_ip\": \"$ACTIVEDOMAINIP\"
			\"active_dns_ip\": \"$ACTIVEDNSIP\"
		},
		\"vpc_id\": \"$VPCID\",
		\"subnet_ids\": [
			{
				\"subnet_id\": \"$SUBNETID\"
			}
		],
		\"access_mode\": \"$ACCESSMODE\",
		\"availablity_zone\": \"$AZ\"
	}"

	export REQ_CREATE_WORKSPACE
}

applyWorkspace()
{
	URL="$AUTH_URL_WORKSPACES"

	if [ "$VPCNAME" != "" ]; then convertVPCNameToId "$VPCNAME"; fi
	if [ "$SUBNETNAME" != "" ]; then convertSUBNETNameToId "$SUBNETNAME" "$VPCID"; fi

	if [ "$DOMAINTYPE" = "LITE_AD" ]; then
		applyWorkspace_getLiteAD
	elif [ "$DOMAINTYPE" = "LOCAL_AD" ]; then
		applyWorkspace_getLocalAD
	else
		echo "ERROR: Domain type '$DOMAINTYPE' not supported" 1>&2
		exit 2
	fi

	echo "$REQ_CREATE_WORKSPACE"

	OUTPUT=`curlpostauth "$TOKEN" "$REQ_CREATE_WORKSPACE" "$URL"`
	RC=$?

	if test $RC != 0; then echo "ERROR creating workspace" 1>&2; exit $RC; fi

	JOBID=$(echo "$OUTPUT" | jq '.job_id' | tr -d '"')
	if test -z "$JOBID" -o "$JOBID" = "null"; then echo "ERROR: $OUTPUT" 2>&1; exit 2; fi
	WaitForWorkspaceJob $JOBID
}

cancelWorkspace()
{
	URL="$AUTH_URL_WORKSPACES"

	OUTPUT=`curldeleteauth "$TOKEN" "$URL"`
	RC=$?

	if test $RC != 0; then echo "ERROR canceling workspace" 1>&2; exit $RC; fi

	JOBID=$(echo "$OUTPUT" | jq '.job_id' | tr -d '"')
	if test -z "$JOBID" -o "$JOBID" = "null"; then echo "ERROR: $OUTPUT" 2>&1; exit 2; fi
	WaitForWorkspaceJob $JOBID
}

listWorkspaceDesktops()
{
	URL="$AUTH_URL_WORKSPACE_DESKTOPS"

	curlgetauth $TOKEN "$URL" | jq -r '.desktops[] | .desktop_id + "   " + .computer_name + "   " + .ip_address + "   " + .user_name + "   " + .user_group + "   " + .desktop_type' | sed -r '/^\s*$/d'

	return ${PIPESTATUS[0]}
}

listWorkspaceProducts()
{
	URL="$AUTH_URL_WORKSPACE_PRODUCTS"

	curlgetauth $TOKEN "$URL" | jq -r '.products[] | .product_id + "   " + .flavor_id + "   " + .type + "   " + .os_type + "   " + .descriptions' | sed -r '/^\s*$/d'

	return ${PIPESTATUS[0]}
}


##########################################################################################

# Package dependency #####################################################################

# check libs3 installed
command -v s3 >/dev/null 2>&1 || { echo -n>&2 "#Note: otc requires libs3 package to be installed for object storage operations.
Please install libs3 or libs3-2 using yum/apt-get/zypper.
Continuing anyway ..."; }

# check jq installed
command -v jq >/dev/null 2>&1 || { echo -n>&2 "ERROR: otc requires jq package to be installed.
Please install jq using yum/apt-get/zypper.
Aborting."; exit 1; }

##########################################################################################

# Command Line Parser ####################################################################

# Insecure
if test "$1" == "--insecure" -o "$1" == "-k"; then
	INS=$1; shift
else
	if test -n "$OS_CACERT"; then INS="--cacert $OS_CACERT"; else unset INS; fi
fi

declare -i DEBUG=0
# Debugging
while test "$1" = "debug"; do let DEBUG+=1; shift; done

# Global options ...
while test "${1:0:2}" == '--'; do
	case "${1:2}" in
		insecure)
			INS="--insecure";;
		debug)
			let DEBUG+=1;;
		unscoped)
			REQSCOPE="unscoped";;
		domainscope)
			REQSCOPE="domain";;
		projectscope)
			REQSCOPE="project";;
		discardcache)
			DISCARDCACHE=1;;
		nocache)
			NOCACHE=1;;
		*)
			echo "ERROR: Unknown option \"$1\"" 1>&2
			exit 1
			#break
			;;
	esac
	shift
done

# Proxy Auth
case "$HTTPS_PROXY" in
	*@*)
		if test -z "$INS"; then INS="--proxy-anyauth";
		else INS="--proxy-anyauth $INS"; fi
		;;
esac

if test $DEBUG = 0; then unset DEBUG; fi

# fetch main command
MAINCOM=$1; shift
# fetch subcommand
SUBCOM=$1; shift

# Global options ...
while test "${1:0:2}" == '--'; do
	case "${1:2}" in
		discardcache)
			DISCARDCACHE=1;;
		domainscope)
			REQSCOPE="domain";;
		projectscope)
			REQSCOPE="project";;
		limit)
			APILIMIT=$2; shift;;
		limit=*)
			APILIMIT=${1:8};;
		offset)
			APIOFFSET=$2; shift;;
		offset=*)
			APIOFFSET=${1:9};;
		marker)
			APIMARKER=$2; shift;;
		marker=*)
			APIMARKER=${1:9};;
		maxgetkb)
			MAXGETKB=$2; shift;;
		maxgetkb=*)
			MAXGETKB=${1:11};;
		*)
			break;;
	esac
	shift
done

# Specific options
if [ "${SUBCOM:0:6}" == "create" -o "${SUBCOM:0:5}" == "apply" -o "${SUBCOM:0:6}" == "cancel" -o "$SUBCOM" == "addlistener" -o "${SUBCOM:0:6}" == "update" -o "$SUBCOM" == "register" -o "$SUBCOM" == "download" -o "$SUBCOM" == "copy" -o "$SUBCOM" == "reboot" -o "$SUBCOM" == "start" -o "$SUBCOM" = "stop" ] || [[ "$SUBCOM" == *-instances ]]; then
	while [[ $# > 0 ]]; do
		key="$1"
		case $key in
			-r|--replace)
				REPLACE=1;;
			-a|--admin-pass)
				ADMINPASS="$2"; shift;;
			-n|--instance-name)
				INSTANCE_NAME="$2"; shift;;
			-6|--ipv6)
				echo "#Note: Use otc.sh publicip6 for IPv6 Floating IPs" 1>&2
				DOPEP=1;;
			--pep)
				DOPEP=1;;
			-t|--instance-id)
				INSTANCE_ID="$2"; shift;;
			--volume-name)
				VOLUME_NAME="$2"; shift;;
			--volume-description)
				VOLUME_DESC="$2"; shift;;
			--dedicated-host|--dedicated-host-id)
				DEDICATED_HOST_ID="$2"; shift;;
			--dedicated)
				TENANCY="dedicated";;
			--file1)
				FILE1="$2"; shift;;
			--file2)
				FILE2="$2"; shift;;
			--file3)
				FILE3="$2"; shift;;
			--file4)
				FILE4="$2"; shift;;
			--file5)
				FILE5="$2"; shift;;
			-t|--instance-type|--flavor)
				INSTANCE_TYPE="$2"; FLAVORSET=1; shift;;
			-i|--image-name)
				IMAGENAME="$2"; shift;;
			--image-id|--image)
				IMAGE_ID="$2"; shift;;
			-c|--count)
				NUMCOUNT="$2"; shift;;
			-b|--subnet-id)
				SUBNETID="$2"; shift;;
			--subnet-name)
				SUBNETNAME="$2"; shift;;
			--nicsubs)
				MORESUBNETS="$2"; shift;;
			--type)
				TYPE="$2"; shift;;
			-v|--vpc-id)
				VPCID="$2"; shift;;
			--vpc-name)
				VPCNAME="$2"; shift;;
			--cidr)
				CIDR="$2"; shift;;
			--gateway-ip)
				GWIP="$2"; shift;;
			--primary-dns)
				PRIMARYDNS="$2"; shift;;
			--secondary-dns)
				SECDNS="$2"; shift;;
			-z|--availability-zone|--az)
				AZ="$2"; shift;;
			-s|--security-group-ids|--security-groups)
				SECUGROUP="$2"; shift;;
			-g|--security-group-name)
				SECUGROUPNAME="$2"; shift;;
			-p|--public)
				case "$2" in
					True|False|true|false|TRUE|FALSE)  CREATE_ECS_WITH_PUBLIC_IP="$(echo $2 | tr 'A-Z' 'a-z')";;
					[0-9]*)      CREATE_ECS_WITH_PUBLIC_IP=false; EIP="$2";;
					*)           echo "ERROR: unsupported value for public IPs" 1>&2; exit 2;;
				esac
				shift;;     # past argument
			--volumes)
				DEV_VOL="$2"; shift;;
			--boot-volume)
				BOOT_VOL="$2"; shift;;
			--disks)
				DISKS="$2"; shift;;
			--disktype|--disk-type)
				VOLUMETYPE="$2"; shift;;
			--disksize|--disk-size)
				ROOTDISKSIZE="$2"; shift;;
			--shareable|--multiattach|--multi-attach)
				SHAREABLE="true";;
			--crypt)
				CRYPTKEYID=$2; shift;;
			--vbd)
				VBD=1;;
			--scsi)
				SCSI=1;;
			--datadisks)
				DATADISKS="$2"; shift;;
			--autorecovery|--auto-recovery)
				AUTORECOV="$(echo $2 | tr 'A-Z' 'a-z')"; shift;;
			--tags)
				TAGS="$2"; shift
				if test "$TAGS" != "${TAGS//@/_at_}"; then
					echo "WARN: \"@\" no longer allowed in tags" 1>&2
				fi;;
			--inherit-tags)
				INHERIT_TAGS=1;;
			--snat)
				SNAT=1;;
			--metadata-json)
				METADATA_JSON="$2"; shift;;
			--metadata)
				METADATA_JSON="$(keyval2json $2)"; shift;;
			--direction)
				DIRECTION="$2"; shift;;
			--portmin|--port-min)
				PORTMIN="$2"; shift;;
			--portmax|--port-max)
				PORTMAX="$2"; shift;;
			--protocol)
				PROTOCOL="$2"; shift;;
			--remotegroup|--remote-group)
				REMGROUPID="$2"; shift;;
			--remoteip|--remote-ip)
				REMIP="$2"; shift;;
			--ethertype|--ether-type)
				ETHERTYPE="$2"; shift;;
			--key-name)
				KEYNAME="$2"; shift;;
			--bandwidth-name)
				BANDWIDTH_NAME=$2; shift;;
			--bandwidth)
				BANDWIDTH=$2; shift;;
			--wait|--poll)
				WAIT_FOR_JOB="true";;
			--nowait)
				WAIT_FOR_JOB="false";;
			--hard)
				ECSACTIONTYPE="HARD";;
			--soft)
				ECSACTIONTYPE="SOFT";;
			--fixed-ip)
				FIXEDIP=$2; shift;;
			--fixed-port)
				FIXEDPORT=$2; shift;;
			--user-data)
				USERDATA=$2; shift;;
			--user-data-file)
				USERDATAFILE=$2; shift;;
			--default)
				DEFAULT=YES;;
			--min-disk)
				MINDISK=$2; shift;;
			--min-ram)
				MINRAM=$2; shift;;
			--cmk_id)
				CMKID=$2;  shift;;			
			--disk-format|--diskformat)
				DISKFORMAT=$2; shift;;
			--os-version)
				OSVERSION="$2"; shift;;
			--property)
				if test -z "$PROPS"; then PROPS="$2"; else PROPS="$PROPS,$2"; fi
				shift;;
			--description)
				DESCRIPTION="$2"; shift;;
			--name)
				NAME="$2"; shift;;
			--domain)
				DOMAIN="$2"; shift;;
			--domain-type)
				DOMAINTYPE="$2"; shift;;
			--domain-name)
				DOMAINNAME="$2"; shift;;
			--domain-admin-account)
				DOMAINADMINACCOUNT="$2"; shift;;
			--domain-admin-password)
				DOMAINADMINPASSWORD="$2"; shift;;
			--active-domain-ip)
				ACTIVEDOMAINIP="$2"; shift;;
			--active-dns-ip)
				ACTIVEDNSIP="$2"; shift;;
			--access-mode)
				ACCESSMODE="$2"; shift;;
			--timeout|--elbtimeout)
				ELBTIMEOUT="$2"; shift;;
			--cookieto|--cookietimeout)
				COOKIETIMEOUT="$2"; shift;;
			--drain)
				ELBDRAIN="$2"; shift;;
			--sslcert|--certificate)
				SSLCERT="$2"; shift;;
			--sslproto)
				SSLPROTO="$2"; shift;;
			--sslcipher)
				SSLCIPHER="$2"; shift;;
			--auto)
				AUTOPLC="$2"; shift;;
			--time)
				BKUPTIME="$2"; shift;;
			--freq)
				BKUPFREQ=$2; shift;;
			--retain)
				BKUPRETAIN=$2; shift;;
			--retain1st)
				BKUPRETFIRST="$2"; shift;;
			--enable)
				OPTENABLE=1;;
			--disable)
				OPTDISABLE=1;;
			--scheduler-hints)
				SCHEDHINT="$2"; shift;;
			--project-id|--tenant-id|--projectid|--tenantid)
				PROJECTID="$2"; shift;;
			--address)
				IPADDR="$1"; shift;;
			-*)
				# unknown option
				echo "ERROR: unknown option \"$1\"" 1>&2
				exit 1;;
			*)
				break;;
		esac

		shift # next argument or value
	done
fi

##########################################################################################

# MAIN ###################################################################################

#echo "Execute $MAINCOM $SUBCOM"

if [ "$MAINCOM" == "s3" ]; then
	s3 $SUBCOM "$@"
	exit $?
fi

# help XXX is the same as XXX help
if [ "$MAINCOM" = "help" -a -n "$SUBCOM" ]; then MAINCOM="$SUBCOM"; SUBCOM="help"; fi

# Support aliases / alternative names
if [ "$MAINCOM" = "server" ]; then MAINCOM="ecs"; fi
if [ "$MAINCOM" = "vm" ]; then MAINCOM="ecs"; fi
if [ "$MAINCOM" = "nova" ]; then MAINCOM="ecs"; fi
if [ "$MAINCOM" = "volumes" ]; then MAINCOM="evs"; fi
if [ "$MAINCOM" = "volume" ]; then MAINCOM="evs"; fi
if [ "$MAINCOM" = "cinder" ]; then MAINCOM="evs"; fi
if [ "$MAINCOM" = "neutron" ]; then MAINCOM="vpc"; fi
if [ "$MAINCOM" = "router" ]; then MAINCOM="vpc"; fi
if [ "$MAINCOM" = "floating-ip" ]; then MAINCOM="publicip"; fi
if [ "$MAINCOM" = "floatingip" ]; then MAINCOM="publicip"; fi
if [ "$MAINCOM" = "eip" ]; then MAINCOM="publicip"; fi
if [ "$MAINCOM" = "image" ]; then MAINCOM="images"; fi
if [ "$MAINCOM" = "glance" ]; then MAINCOM="images"; fi
if [ "$MAINCOM" = "sg" ]; then MAINCOM="security-group"; fi
if [ "$MAINCOM" = "securitygroup" ]; then MAINCOM="security-group"; fi
if [ "$MAINCOM" = "vbs" ]; then MAINCOM="backup"; fi
if [ "$MAINCOM" = "auth" ]; then MAINCOM="iam"; fi
if [ "$MAINCOM" = "identity" ]; then MAINCOM="iam"; fi
if [ "$MAINCOM" = "keystone" ]; then MAINCOM="iam"; fi
if [ "$MAINCOM" = "ces" ]; then MAINCOM="metrics"; fi
if [ "$MAINCOM" = "metric" ]; then MAINCOM="metrics"; fi
if [ "$MAINCOM" = "alarm" ]; then MAINCOM="alarms"; fi
if [ "$MAINCOM" = "dns" ]; then MAINCOM="domain"; fi
if [ "$MAINCOM" = "cce" ]; then MAINCOM="cluster"; fi
if [ "$MAINCOM" = "magnum" ]; then MAINCOM="cluster"; fi
if [ "$MAINCOM" = "traces" ]; then MAINCOM="trace"; fi
if [ "$MAINCOM" = "cts" ]; then MAINCOM="trace"; fi
#if [ "$MAINCOM" = "snm" ]; then MAINCOM="notifications"; fi
if [ "$MAINCOM" = "smn" ]; then MAINCOM="notifications"; fi
if [ "$MAINCOM" = "notification" ]; then MAINCOM="notifications"; fi
if [ "$MAINCOM" = "topics" ]; then MAINCOM="notifications"; fi
if [ "$MAINCOM" = "topic" ]; then MAINCOM="notifications"; fi
if [ "$MAINCOM" = "dms" ]; then MAINCOM="queues"; fi
if [ "$MAINCOM" = "queue" ]; then MAINCOM="queues"; fi
if [ "$MAINCOM" = "consumers" ]; then MAINCOM="consumer"; fi
if [ "$MAINCOM" = "db" ]; then MAINCOM="rds"; fi
if [ "$MAINCOM" = "trove" ]; then MAINCOM="rds"; fi
if [ "$MAINCOM" = "heat" ]; then MAINCOM="stack"; fi
if [ "$MAINCOM" = "rts" ]; then MAINCOM="stack"; fi
if [ "$MAINCOM" = "lbaas" ]; then MAINCOM="ulb"; fi
if [ "$MAINCOM" = "octavia" ]; then MAINCOM="ulb"; fi
if [ "$MAINCOM" = "vlb" ]; then MAINCOM="ulb"; fi
if [ "$MAINCOM" = "sfs" ]; then MAINCOM="shares"; fi
if [ "$MAINCOM" = "manila" ]; then MAINCOM="shares"; fi
if [ "$MAINCOM" = "tms" ]; then MAINCOM="tags"; fi
if [ "$MAINCOM" = "dcs" ]; then MAINCOM="cache"; fi
if [ "$MAINCOM" = "warehouse" ]; then MAINCOM="dws"; fi
if [ "$MAINCOM" = "datawarehouse" ]; then MAINCOM="dws"; fi
if [ "$MAINCOM" = "csbs" ]; then MAINCOM="serverbackup"; fi
if [ "$MAINCOM" = "maas" ]; then MAINCOM="migration"; fi
if [ "$MAINCOM" = "designate" ]; then MAINCOM="domain"; fi
if [ "$MAINCOM" = "tag" ]; then MAINCOM="tags"; fi
if [ "$MAINCOM" = "product" ]; then MAINCOM="products"; fi
if [ "$MAINCOM" = "marketplace" ]; then MAINCOM="products"; fi
if [ "$MAINCOM" = "natgw" ]; then MAINCOM="nat"; fi
if [ "$MAINCOM" = "as" ]; then MAINCOM="asgroup"; fi
if [ "$MAINCOM" = "workspaces" ]; then MAINCOM="workspace"; fi
if [ "$MAINCOM" = "workspace-desktops" ]; then MAINCOM="workspace-desktop"; fi
if [ "$MAINCOM" = "workspace-products" ]; then MAINCOM="workspace-product"; fi

# Some IAM functions need special handling
if [ "$MAINCOM" = "iam" -a "$SUBCOM" = "catalog" ]; then OUTPUT_CAT=1; fi
if [ "$MAINCOM" = "iam" -a "$SUBCOM" = "roles" ]; then OUTPUT_ROLES=1; fi
if [ "$MAINCOM" = "iam" -a "$SUBCOM" = "domain" ]; then OUTPUT_DOM=1; fi
if [ "$MAINCOM" = "iam" -a "$SUBCOM" = "deletetoken" ]; then DEL_TOKEN=1; fi

if [ -n "$MAINCOM" -a "$MAINCOM" != "help" -a "$MAINCOM" != "mds" -a "$SUBCOM" != "help" ]; then
	if [ "$MAINCOM" == "iam" -a -z "$REQSCOPE" ] && \
		[  "$SUBCOM" != "token" -a "$SUBCOM" != "project" -a "$SUBCOM" != "catalog" \
		-a "$SUBCOM" != "services" -a "$SUBCOM" != "endpoints" -a "$SUBCOM" != "roles" \
		-a "$SUBCOM" != "domain" ]; then
		REQSCOPE="domain"
	fi
	if [ "$MAINCOM" == "tags" ]; then REQSCOPE="domain"; fi
	getIAMToken $REQSCOPE
	ERR=$?
fi

#if [ "$MAINCOM" = "rds" -a $TROVE_OVERRIDE = 1 ]; then
#	echo "WARN: Using manually set database endpoint, not advertized in catalog" 1>&2
#fi

if [ "$MAINCOM" == "help" -o "$MAINCOM" == "-h" -o "$MAINCOM" == "--help" ]; then
	printHelp

elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "help" ]; then
	ecsHelp
elif [ "$MAINCOM" == "ecs"  -a "$SUBCOM" == "list-short" ]; then
	getShortECSList "$@"
elif [ "$MAINCOM" == "ecs"  -a "$SUBCOM" == "list" ]; then
	getECSList "$@"
elif [ "$MAINCOM" == "ecs"  -a "$SUBCOM" == "listwithtags" ]; then
	getECSListWithTags "$@"
elif [ "$MAINCOM" == "ecs"  -a "$SUBCOM" == "list-detail" ]; then
	getECSDetail "$1"
elif [ "$MAINCOM" == "ecs"  -a "$SUBCOM" == "details" ]; then
	getECSDetailsNew "$1"

elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "show" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "vm" ]; then
	getECSVM $1
elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "show2" ]; then
	getECSv2 $1

elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "limits" ]; then
	getLimits

elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "console-log" ]; then
	getECSlog $1

elif [ "$MAINCOM" == "ecs"  -a "$SUBCOM" == "create2" ] ||
     [ "$MAINCOM" == "ecs"  -a "$SUBCOM" == "create" -a "${INSTANCE_TYPE:0:8}" == "physical" ] ||
     [ "$MAINCOM" == "ecs"  -a "$SUBCOM" == "create" -a -n "$BOOT_VOL" ]; then
	ECSprepare $1
	ECSCreatev2 "$NUMCOUNT" "$INSTANCE_TYPE" "$IMAGE_ID" "$VPCID" "$SUBNETID" "$SECUGROUP"

elif [ "$MAINCOM" == "ecs"  -a "$SUBCOM" == "create" ]; then
	ECSprepare $1
	#if test -n "$DEBUG"; then echo ECSCreate "$NUMCOUNT" "$INSTANCE_TYPE" "$IMAGE_ID" "$VPCID" "$SUBNETID" "$SECUGROUP"; fi
	ECSCreate "$NUMCOUNT" "$INSTANCE_TYPE" "$IMAGE_ID" "$VPCID" "$SUBNETID" "$SECUGROUP"
	echo "Task ID: $ECSTASKID"

	ECSID="null"
	if [ "$NUMCOUNT" == 1 ] && [ -n "$DEV_VOL" -o "$WAIT_FOR_JOB" != "false" ]; then
		WaitForSubTask $ECSTASKID 4    ##### => generate $ECSSUBTASKID (to get server_id=ECSID)
		declare -i ctr=0
		while [ null = "$ECSID" -a $ctr -le 400 ]; do
			echo -n "."
			let ctr+=1
			sleep 4
			getECSJOBList $ECSSUBTASKID
			ECSID=$(echo "$ECSJOBSTATUSJSON" | jq '.entities.server_id' 2>/dev/null | tr -d '"')
			if test "$(echo $ECSJOBSTATUSJSON | jq '.status' | tr -d '"')" == "FAIL"; then
				echo "ERROR: Job $ECSSUBTASKID failed" 1>&2
				echo "$ECSJOBSTATUSJSON" | jq '.' 1>&2
				exit 8
			fi
		done
		if test $ctr -ge 500; then echo "TIMEOUT"; else echo; fi
		#FIXME: Old code, disabled
		if false && test -n "$EIP" -a "$ECSID" != "null"; then
			BindPublicIpToCreatingVM || echo "ERROR binding external IP $EIP" >&2
		fi
		#if test -n "$AUTORECOV"; then setAutoRecov $ECSID; fi
	fi

	WaitForTask $ECSTASKID 2
	if [ "null" == "$ECSID" ]; then
		ECSID=$(echo "$ECSJOBSTATUSJSON" | jq '.entities.sub_jobs[].entities.server_id' 2>/dev/null | tr -d '"')
	fi
	if [ -n "$ECSID" -a "null" != "$ECSID" ]; then
		inheritTags
		echo "ECS ID: $ECSID"
	fi
	echo "ECS Creation status: $ECSJOBSTATUS"
	[ "$NUMCOUNT" = 1 ] && [ -n "$DEV_VOL" ] && ECSAttachVolumeListName "$ECSID" "$DEV_VOL"
	if [ "$ECSJOBSTATUS" != "SUCCESS" -a "$ECSJOBSTATUS" != "RUNNING" ]; then
		exit 1
	fi

elif [ "$MAINCOM" == "ecs"  -a "$SUBCOM" == "reboot-instances" ] ||
     [ "$MAINCOM" == "ecs"  -a "$SUBCOM" == "reboot" ]; then
	export ECSACTION="reboot"
	export ECSACTIONSERVERID=$1

	if [ "$ECSACTIONSERVERID" == "" ]; then
		echo "ERROR: Must specify the Instance ID!" 1>&2
		ecsHelp
		exit 1
	fi

	ECSAction

elif [ "$MAINCOM" == "ecs"  -a "$SUBCOM" == "start-instances" ] ||
     [ "$MAINCOM" == "ecs"  -a "$SUBCOM" == "start" ]; then
	ECSACTION="os-start"
	ECSACTIONSERVERID=$1
	if [ "$ECSACTIONSERVERID" == "" ]; then
		echo "ERROR: Must specify the Instance ID!" 1>&2
		ecsHelp
		exit 1
	fi

	ECSAction

elif [ "$MAINCOM" == "ecs"  -a "$SUBCOM" == "stop-instances" ] ||
     [ "$MAINCOM" == "ecs"  -a "$SUBCOM" == "stop" ]; then
	ECSACTION="os-stop"
	ECSACTIONSERVERID=$1

	if [ "$ECSACTIONSERVERID" == "" ]; then
	echo "ERROR: Must specify the Instance ID!" 1>&2
		ecsHelp
		exit 1
	fi

	ECSAction

elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "job" ] ||
     [ "$MAINCOM" == "task" -a "$SUBCOM" == "show" ]; then
	#ECSTASKID=$1
	#echo $AUTH_URL_ECS_JOB/$1
	getECSJOBList $1
	echo "$ECSJOBSTATUSJSON"

elif [ "$MAINCOM" == "task" -a "$SUBCOM" == "delete" ]; then
	DeleteTask $1
elif [ "$MAINCOM" == "task" -a "$SUBCOM" == "wait" ]; then
	WAIT_FOR_JOB=true
	WaitForTask "$@"
elif [ "$MAINCOM" == "task" -a "$SUBCOM" == "help" ]; then
	taskHelp

elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "delete" ]; then
	ECSDelete $@
	WaitForTask $ECSTASKID 2
elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "update" ]; then
	ECSUpdate "$@"
elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "az-list" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "listaz" ]; then
	getAZList
elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "az-show" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "showaz" ]; then
	getAZDetail "$1"
elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "attach-nic" ]; then
	ECSAttachPort "$@"
elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "detach-nic" ]; then
	ECSDetachPort "$@"

elif [ "$MAINCOM" == "vpc" -a "$SUBCOM" == "help" ] ||
	  [ "$MAINCOM" == "vpcpeer" -a "$SUBCOM" == "help" ]; then
	vpcHelp
elif [ "$MAINCOM" == "vpc"  -a "$SUBCOM" == "list" ]; then
	getVPCList
elif [ "$MAINCOM" == "vpc"  -a "$SUBCOM" == "show" ]; then
	getVPCDetail $1
elif [ "$MAINCOM" == "vpc"  -a "$SUBCOM" == "show2" ]; then
	getVPCDetail2 $1
elif [ "$MAINCOM" == "vpc"  -a "$SUBCOM" == "delete" ]; then
	VPCDelete $1
elif [ "$MAINCOM" == "vpc"  -a "$SUBCOM" == "create" ]; then
	VPCCreate $1
elif [ "$MAINCOM" == "vpc"  -a "$SUBCOM" == "listroutes" ] ||
     [ "$MAINCOM" == "vpc"  -a "$SUBCOM" == "route-list" ]; then
	getVPCRoutes "$@"
elif [ "$MAINCOM" == "vpc"  -a "$SUBCOM" == "addroute" ] ||
     [ "$MAINCOM" == "vpc"  -a "$SUBCOM" == "route-add" ] ||
     [ "$MAINCOM" == "vpc"  -a "$SUBCOM" == "route-create" ]; then
	addVPCRoute "$@"
elif [ "$MAINCOM" == "vpc"  -a "$SUBCOM" == "deleteroute" ] ||
     [ "$MAINCOM" == "vpc"  -a "$SUBCOM" == "route-delete" ] ||
     [ "$MAINCOM" == "vpc"  -a "$SUBCOM" == "route-del" ] ||
     [ "$MAINCOM" == "vpc"  -a "$SUBCOM" == "delroute" ]; then
	deleteVPCRoute "$@"
elif [ "$MAINCOM" == "vpc"  -a "$SUBCOM" == "enable-snat" ]; then
	enableVPCSNAT $1
elif [ "$MAINCOM" == "vpc"  -a "$SUBCOM" == "disable-snat" ]; then
	disableVPCSNAT $1
elif [ "$MAINCOM" == "vpc"  -a "$SUBCOM" == "limits" ]; then
	getVPCLimits

elif [ "$MAINCOM" == "vpcpeer"  -a "$SUBCOM" == "list" ]; then
	getVPCPeerList "$@"
elif [ "$MAINCOM" == "vpcpeer"  -a "$SUBCOM" == "show" ]; then
	getVPCPeerDetail "$@"
elif [ "$MAINCOM" == "vpcpeer"  -a "$SUBCOM" == "create" ]; then
	createVPCPeer "$@"
elif [ "$MAINCOM" == "vpcpeer"  -a "$SUBCOM" == "update" ]; then
	updateVPCPeer "$@"
elif [ "$MAINCOM" == "vpcpeer"  -a "$SUBCOM" == "accept" ]; then
	acceptVPCPeer "$@"
elif [ "$MAINCOM" == "vpcpeer"  -a "$SUBCOM" == "refuse" ] ||
     [ "$MAINCOM" == "vpcpeer"  -a "$SUBCOM" == "reject" ]; then
	rejectVPCPeer "$@"
elif [ "$MAINCOM" == "vpcpeer"  -a "$SUBCOM" == "delete" ]; then
	deleteVPCPeer "$@"

elif [ "$MAINCOM" == "publicip" -a "$SUBCOM" == "help" ] ||
     [ "$MAINCOM" == "publicip6" -a "$SUBCOM" == "help" ]; then
	eipHelp
elif [ "$MAINCOM" == "publicip"  -a "$SUBCOM" == "list" ]; then
	getPUBLICIPSList
elif [ "$MAINCOM" == "publicip"  -a "$SUBCOM" == "show" ]; then
	getPUBLICIPSDetail $1
elif [ "$MAINCOM" == "publicip"  -a "$SUBCOM" == "create" ]; then
	PUBLICIPSCreate "$@"
elif [ "$MAINCOM" == "publicip"  -a "$SUBCOM" == "update" ]; then
	PUBLICIPSUpdate "$@"
elif [ "$MAINCOM" == "publicip"  -a "$SUBCOM" == "delete" ]; then
	PUBLICIPSDelete $@
elif [ "$MAINCOM" == "publicip" -a "$SUBCOM" == "bind" ] ||
     [ "$MAINCOM" == "publicip" -a "$SUBCOM" == "associate" ]; then
	PUBLICIPSBind $@
elif [ "$MAINCOM" == "publicip" -a "$SUBCOM" == "unbind" ] ||
     [ "$MAINCOM" == "publicip" -a "$SUBCOM" == "disassociate" ]; then
	PUBLICIPSUnbind $@
elif [ "$MAINCOM" == "publicip" -a "$SUBCOM" == find ]; then
	convertEipToId $1
	echo "$EIP_ID   $EIP_IP   $EIP_STATUS"

elif [ "$MAINCOM" == "publicip6"  -a "$SUBCOM" == "list" ]; then
	getPUBLICIPS6List
elif [ "$MAINCOM" == "publicip6"  -a "$SUBCOM" == "show" ]; then
	getPUBLICIPS6Detail $1
elif [ "$MAINCOM" == "publicip6"  -a "$SUBCOM" == "create" ]; then
	PUBLICIPS6Create "$@"
elif [ "$MAINCOM" == "publicip6"  -a "$SUBCOM" == "update" ]; then
	PUBLICIPS6Update "$@"
elif [ "$MAINCOM" == "publicip6"  -a "$SUBCOM" == "delete" ]; then
	PUBLICIPS6Delete $@
elif [ "$MAINCOM" == "publicip6" -a "$SUBCOM" == "bind" ] ||
     [ "$MAINCOM" == "publicip6" -a "$SUBCOM" == "associate" ]; then
	PUBLICIPS6Bind $@
elif [ "$MAINCOM" == "publicip6" -a "$SUBCOM" == "unbind" ] ||
     [ "$MAINCOM" == "publicip6" -a "$SUBCOM" == "disassociate" ]; then
	PUBLICIPS6Unbind $@
elif [ "$MAINCOM" == "publicip6" -a "$SUBCOM" == find ]; then
	convertEip6ToId $1
	echo "$EIP_ID   $EIP_IP   $EIP_STATUS"

elif [ "$MAINCOM" == "subnet" -a "$SUBCOM" == "help" ]; then
	subnetHelp
elif [ "$MAINCOM" == "subnet"  -a "$SUBCOM" == "list" ]; then
	getSUBNETList #"$@"
elif [ "$MAINCOM" == "subnet"  -a "$SUBCOM" == "show" ]; then
	getSUBNETDetail "$1"
elif [ "$MAINCOM" == "subnet"  -a "$SUBCOM" == "delete" ]; then
	if test "$2" == "--vpc-name"; then convertVPCNameToId "$3"; fi
	if test "$2" == "--vpc-id"; then VPCID="$3"; fi
	SUBNETDelete "$1"
elif [ "$MAINCOM" == "subnet"  -a "$SUBCOM" == "namelist" ]; then
	# FIXME -- what should this do?
	IMAGENAME=$1
	# convertSUBNETNameToId "$SUBNETNAME" "$VPIC_ID"
	# convertSECUGROUPNameToId "$SECUGROUPNAME"
	# convertIMAGENameToId "$IMAGENAME"
elif [ "$MAINCOM" == "subnet"  -a "$SUBCOM" == "create" ]; then
	if [ "$VPCNAME" != "" ]; then convertVPCNameToId "$VPCNAME"; fi
	SUBNETCreate

elif [ "$MAINCOM" == "security-group" -a "$SUBCOM" == "help" ]; then
	sgHelp
elif [ "$MAINCOM" == "security-group"  -a "$SUBCOM" == "list" ]; then
	VPCNAME=$1
	if [ "$VPCNAME" != "" ]; then convertVPCNameToId "$VPCNAME"; shift; fi
	getSECGROUPList #"$@"
elif [ "$MAINCOM" == "security-group"  -a "$SUBCOM" == "create" ]; then
	if [ -n "$VPCNAME" -a -z "$VPCID" ]; then convertVPCNameToId "$VPCNAME"; fi
	SECGROUPCreate "$@"
elif [ "$MAINCOM" == "security-group-rules" -a "$SUBCOM" == "list" ] ||
     [ "$MAINCOM" == "security-group" -a "$SUBCOM" == "show" ]; then
	if [ -z "$1" ]; then
		echo "ERROR: Must specify the Security Group ID!" 1>&2
		sgHelp
		exit 1
	fi
	#AUTH_URL_SEC_GROUP_RULES="${BASEURL/iam/vpc}/v1/$OS_PROJECT_ID/security-group-rules/$SECUGROUP"
	getSECGROUPRULESList $1
elif [ "$MAINCOM" == "security-group-rules"  -a "$SUBCOM" == "create" ]; then
	if [ "$VPCNAME" != "" ]; then convertVPCNameToId "$VPCNAME"; fi
	if [ "$SECUGROUPNAME" != "" ]; then convertSECUGROUPNameToId "$SECUGROUPNAME"; fi
	#AUTH_URL_SEC_GROUP_RULES="${BASEURL/iam/vpc}/v1/$OS_PROJECT_ID/security-group-rules"
	SECGROUPRULECreate
elif [ "$MAINCOM" == "security-group"  -a "$SUBCOM" == "delete" ]; then
	SECGROUPDelete "$@"

elif [ "$MAINCOM" == "images" -a "$SUBCOM" == "help" ]; then
	imageHelp
elif [ "$MAINCOM" == "images"  -a "$SUBCOM" == "list" ]; then
	getIMAGEList "$@"
elif [ "$MAINCOM" == "images"  -a "$SUBCOM" == "show" ]; then
	getIMAGEDetail $1
elif [ "$MAINCOM" == "images"  -a "$SUBCOM" == "upload" ]; then
	if test -r "$2"; then
		uploadIMAGEfile $1 $2
	else
		uploadIMAGEobj $1 $2
	fi
elif [ "$MAINCOM" == "images"  -a "$SUBCOM" == "create" ]; then
	createIMAGE "$1"
elif [ "$MAINCOM" == "images"  -a "$SUBCOM" == "copy" ]; then
	copyIMAGE "$1" "$2"
elif [ "$MAINCOM" == "images"  -a "$SUBCOM" == "register" ]; then
	registerIMAGE "$1" "$2"
elif [ "$MAINCOM" == "images"  -a "$SUBCOM" == "delete" ]; then
	for img in "$@"; do deleteIMAGE $img; done
elif [ "$MAINCOM" == "images"  -a "$SUBCOM" == "update" ]; then
	updateIMAGE "$1"
elif [ "$MAINCOM" == "images"  -a "$SUBCOM" == "download" ]; then
	downloadIMAGE "$@"
	WaitForTask $IMGJOBID 5
elif [ "$MAINCOM" == "images" -a "$SUBCOM" == "listmember" ] ||
     [ "$MAINCOM" == "images" -a "$SUBCOM" == "listshare" ] ||
     [ "$MAINCOM" == "images" -a "$SUBCOM" == "members" ]; then
	getImgMemberList "$@"
elif [ "$MAINCOM" == "images" -a "$SUBCOM" == "showmember" ] ||
     [ "$MAINCOM" == "images" -a "$SUBCOM" == "showshare" ]; then
	getImgMemberDetail "$@"
elif [ "$MAINCOM" == "images" -a "$SUBCOM" == "addmember" ] ||
     [ "$MAINCOM" == "images" -a "$SUBCOM" == "share" ]; then
	ImgMemberCreate "$@"
elif [ "$MAINCOM" == "images" -a "$SUBCOM" == "delmember" ] ||
     [ "$MAINCOM" == "images" -a "$SUBCOM" == "unshare" ]; then
	ImgMemberDelete "$@"
elif [ "$MAINCOM" == "images" -a "$SUBCOM" == "acceptmember" ] ||
     [ "$MAINCOM" == "images" -a "$SUBCOM" == "acceptshare" ]; then
	ImgMemberAccept "$@"
elif [ "$MAINCOM" == "images" -a "$SUBCOM" == "rejectmember" ] ||
     [ "$MAINCOM" == "images" -a "$SUBCOM" == "rejectshare" ]; then
	ImgMemberReject "$@"

elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "flavor-list" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "listflavor" ]  ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "flavors" ]; then
	getFLAVORList

elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "flavor-pretty" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "flp" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "pflav" ]; then
	prettyFLAVORList "$@"

elif [ "$MAINCOM" == "keypair" -a "$SUBCOM" == "list" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "listkey" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "keyname-list" ]; then
	getKEYPAIRList

elif [ "$MAINCOM" == "keypair" -a "$SUBCOM" == "show" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "showkey" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "keyname-show" ]; then
	getKEYPAIR "$@"

elif [ "$MAINCOM" == "keypair" -a "$SUBCOM" == "create" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "createkey" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "keyname-create" ]; then
	createKEYPAIR "$@"

elif [ "$MAINCOM" == "keypair" -a "$SUBCOM" == "delete" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "delkey" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "keyname-delete" ]; then
	deleteKEYPAIR "$@"
elif [ "$MAINCOM" == "keypair" -a "$SUBCOM" == "help" ]; then
	keypairHelp

elif [ "$MAINCOM" == "iam" -a "$SUBCOM" == "help" ]; then
	iamHelp
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "token" ]; then
	echo $TOKEN
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "deletetoken" ]; then
	echo -n ""
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "endpoints" ]; then
	curlgetauth $TOKEN "${IAM_AUTH_URL%auth*}endpoints" | jq '.' #'.[]'
	ERR=${PIPESTATUS[0]}
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "listdomain" ] ||
     [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "listdomains" ]; then
	curlgetauth $TOKEN "${IAM_AUTH_URL%tokens}domains" | jq 'def tostr(v): v|tostring; .domains[] | .id+"   "+.name+"   "+tostr(.enabled)+"   "+.description' | tr -d '"'
	ERR=${PIPESTATUS[0]}
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "domains" ]; then
	curlgetauth $TOKEN "${IAM_AUTH_URL%tokens}domains" | jq '.'
	ERR=${PIPESTATUS[0]}
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "services" ]; then
	curlgetauth $TOKEN "${IAM_AUTH_URL%auth*}services" | jq '.' #'.[]'
	ERR=${PIPESTATUS[0]}
# These are not (yet) supported on OTC
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "regions" ]; then
	curlgetauth $TOKEN "${IAM_AUTH_URL%/auth*}/regions" | jq '.' #'.[]'
	ERR=${PIPESTATUS[0]}
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "catalog" -o "$SUBCOM" == "domain" ]; then
   echo -n ""
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "catalog2" ]; then
	curlgetauth $TOKEN "${IAM_AUTH_URL%/tokens}/catalog" | jq '.' #'.[]'
	ERR=${PIPESTATUS[0]}
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "users" ]; then
	curlgetauth $TOKEN "${IAM_AUTH_URL%/auth*}/users" | jq '.' #'.[]'
	ERR=${PIPESTATUS[0]}
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "listuser" ] ||
     [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "listusers" ]; then
	curlgetauth $TOKEN "${IAM_AUTH_URL%/auth*}/users" | jq 'def tostr(s): s|tostring; .users[] | .id+"   "+.name+"   "+tostr(.enabled)+"   "+.description+"   "+.password_expires_at+"   "+.countrycode' | tr -d '"'
	ERR=${PIPESTATUS[0]}
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "adduser" ]; then
	addUser "$@"
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "changeuser" ]; then
	changeUser "$@"
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "showuser" ]; then
	showUser "$@"
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "deluser" ] ||
     [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "deleteuser" ]; then
	delUser "$@"
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "roles" ]; then
   echo -n ""
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "userroles" ]; then
   listRoleAssign "$@"
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "roles2" ]; then
	#curlgetauth $TOKEN "${IAM_AUTH_URL%/auth*}/roles" | jq '.roles[] | .id+"   "+.name+"   "+.catalog+"   "+.display_name+"   "+.policy.Depends[].display_name' | tr -d '"'
	curlgetauth $TOKEN "${IAM_AUTH_URL%/auth*}/roles" | jq '.' #'.[]'
	ERR=${PIPESTATUS[0]}
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "listrole" ] ||
     [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "listroles" ] ||
     [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "listroles2" ] ; then
	curlgetauth $TOKEN "${IAM_AUTH_URL%/auth*}/roles" | jq 'def tostr(v): v|tostring; .roles[] | .id+"   "+.name+"   "+.catalog+"   "+.display_name+"   "+.type+"   "+tostr(.policy.Statement)+"   "+tostr(.policy.Depends)' | tr -d '\\' | tr -d '"'
	ERR=${PIPESTATUS[0]}
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "showrole" ]; then
	# FIXME: RoleName -> ID
   curlgetauth $TOKEN "${IAM_AUTH_URL%/auth*}/roles/$1" | jq -r '.'
	ERR=${PIPESTATUS[0]}
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "listroleuser" ] ||
     [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "listrolegroup" ]; then
	listRoleUser $SUBCOM "$@"
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "addroleuser" ] ||
     [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "addrolegroup" ]; then
	addRoleUser $SUBCOM "$@"
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "delroleuser" ] ||
     [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "deleterolegroup" ] ||
     [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "delrolegroup" ] ||
     [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "deleterolegroup" ]; then
	delRoleUser $SUBCOM "$@"
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "policies" ]; then
	curlgetauth $TOKEN "${IAM_AUTH_URL%/auth*}/policies" | jq '.' #'.[]'
	ERR=${PIPESTATUS[0]}
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "groups" ]; then
	curlgetauth $TOKEN "${IAM_AUTH_URL%/auth*}/groups" | jq '.'
	ERR=${PIPESTATUS[0]}
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "listgroup" ] ||
     [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "listgroups" ]; then
	curlgetauth $TOKEN "${IAM_AUTH_URL%/auth*}/groups" | jq '.groups[] | .id+"   "+.name+"   "+.description+"   "' | tr -d '"'
	ERR=${PIPESTATUS[0]}
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "addgroup" ]; then
	addGroup "$@"
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "changegroup" ]; then
	changeGroup "$@"
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "showgroup" ]; then
	showGroup "$@"
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "listusergroup" ]; then
	listGroup "$@"
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "checkgroup" ]; then
	checkGroup "$@"
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "delgroup" ] ||
     [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "deletegroup" ]; then
	delGroup "$@"
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "addgroupuser" ]; then
	addGroupUser "$@"
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "delgroupuser" ]; then
	delGroupUser "$@"
# End of unsupported APIs
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "projects" ]; then
	curlgetauth $TOKEN "${IAM_AUTH_URL%/auth*}/projects" | jq '.' #'.[]'
	ERR=${PIPESTATUS[0]}
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "listproject" ] ||
     [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "project-list" ] ||
     [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "listprojects" ]; then
	curlgetauth $TOKEN "${IAM_AUTH_URL%/auth*}/auth/projects" | jq '.projects[] | .id+"   "+.name+"   "+.description' | tr -d '"'
	ERR=${PIPESTATUS[0]}
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "listextproject" ] ||
     [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "project-list-ext" ] ||
     [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "listextprojects" ]; then
	curlgetauth $TOKEN "${IAM_AUTH_URL%/auth*}-ext/auth/projects" | jq '.projects[] | .id+"   "+.name+"   "+.status+"   "+.description' | tr -d '"'
	ERR=${PIPESTATUS[0]}
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "createproject" ]; then
	createPROJECT "$@"
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "deleteproject" ]; then
	deletePROJECT "$@"
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "cleanproject" ]; then
	deletePROJECText "$@"
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "recoverproject" ]; then
	recoverPROJECText "$@"
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "showproject" ]; then
	ID="$(uriencode $1)"
	if ! is_id "$ID"; then ID=`curlgetauth "$TOKEN" "${IAM_AUTH_URL%/auth*}/projects?name=$ID" | jq '.projects[].id' | tr -d '"'`; fi
	if test -z "$ID"; then echo "No such project" 1>&2; exit 2; fi
	curlgetauth $TOKEN "${IAM_AUTH_URL%/auth*}/projects/$ID" | jq -r '.'
	ERR=${PIPESTATUS[0]}
elif [ "$MAINCOM" == "iam"  -a "$SUBCOM" == "showextproject" ]; then
	ID="$(uriencode $1)"
	if ! is_id "$ID"; then ID=`curlgetauth "$TOKEN" "${IAM_AUTH_URL%/auth*}/projects?name=$ID" | jq '.projects[].id' | tr -d '"'`; fi
	if test -z "$ID"; then echo "No such project" 1>&2; exit 2; fi
	curlgetauth $TOKEN "${IAM_AUTH_URL%/auth*}-ext/projects/$ID" | jq -r '.'
	ERR=${PIPESTATUS[0]}
elif [ "$MAINCOM" == "iam" -a "$SUBCOM" == "project" ] ||
     [ "$MAINCOM" == "iam" -a "$SUBCOM" == "tenant" ]; then
	echo $OS_PROJECT_ID
elif [ "$MAINCOM" == "iam" -a "$SUBCOM" == "listidp" ]; then
	curlgetauth "$TOKEN" "${IAM_AUTH_URL%/auth*}/OS-FEDERATION/identity_providers" | jq -r 'def str(v): v|tostring; .identity_providers[] | .id+"   "+str(.enabled)+"   "+.links.self+"   "+.description'
	ERR=${PIPESTATUS[0]}
elif [ "$MAINCOM" == "iam" -a "$SUBCOM" == "showidp" ]; then
	curlgetauth "$TOKEN" "${IAM_AUTH_URL%/auth*}/OS-FEDERATION/identity_providers/$1" | jq -r '.'
	ERR=${PIPESTATUS[0]}
elif [ "$MAINCOM" == "iam" -a "$SUBCOM" == "listmapping" ]; then
	curlgetauth "$TOKEN" "${IAM_AUTH_URL%/auth*}/OS-FEDERATION/mappings" | jq -r 'def str(s): s|tostring; .mappings[] | .id+"   "+.links.self+"   "+str(.rules[].local)+"   "+str(.rules[].remote)'
	ERR=${PIPESTATUS[0]}
elif [ "$MAINCOM" == "iam" -a "$SUBCOM" == "showmapping" ]; then
	curlgetauth "$TOKEN" "${IAM_AUTH_URL%/auth*}/OS-FEDERATION/mappings/$1" | jq -r '.'
	ERR=${PIPESTATUS[0]}
elif [ "$MAINCOM" == "iam" -a "$SUBCOM" == "listprotocol" ]; then
	curlgetauth "$TOKEN" "${IAM_AUTH_URL%/auth*}/OS-FEDERATION/protocols" | jq -r '.protocols[] | .id+"   "+.mapping_id+"   "+.links.self'
	ERR=${PIPESTATUS[0]}
elif [ "$MAINCOM" == "iam" -a "$SUBCOM" == "showprotocol" ]; then
	curlgetauth "$TOKEN" "${IAM_AUTH_URL%/auth*}/OS-FEDERATION/protocols/$1" | jq -r '.'
	ERR=${PIPESTATUS[0]}
elif [ "$MAINCOM" == "iam" -a "$SUBCOM" == "keystonemeta" ]; then
	curlgetauth "$TOKEN" "${IAM_AUTH_URL%/auth*}-ext/auth/OS-FEDERATION/SSO/metadata"
	ERR=$?
   echo

elif  [ "$MAINCOM" == "evs" -a "$SUBCOM" == "help" ]; then
	evsHelp
elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "volume-list" ] ||
     [ "$MAINCOM" == "evs" -a "$SUBCOM" == "list" ]; then
	getEVSList "$@"
elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "volume-details" ] ||
     [ "$MAINCOM" == "evs" -a "$SUBCOM" == "details" ]; then
	getEVSListOTC "$@"
elif [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "volume-show" ] ||
     [ "$MAINCOM" == "ecs" -a "$SUBCOM" == "describe-volumes" ] ||
     [ "$MAINCOM" == "evs" -a "$SUBCOM" == "show" ]; then
	getEVSDetail $1
elif [ "$MAINCOM" == "evs" -a "$SUBCOM" == "describe" ]; then
	getEVSDetailExt $1
elif [ "$MAINCOM" == "evs" -a "$SUBCOM" == "tags" ]; then
	getEVSTags $1
elif [ "$MAINCOM" == "evs" -a "$SUBCOM" == "create" ]; then
	EVSCreate
	echo "Task ID: $EVSTASKID"
	#WaitForTask $EVSTASKID 2
	WaitForTaskFieldOpt $EVSTASKID '.entities.volume_id' 5
elif [ "$MAINCOM" == "evs"  -a "$SUBCOM" == "update" ]; then
	EVSUpdate "$@"
elif [ "$MAINCOM" == "evs"  -a "$SUBCOM" == "delete" ]; then
	EVSDelete "$@"
	echo "Task ID: $EVSTASKID"
	WaitForTask $EVSTASKID 2
elif [ "$MAINCOM" == "evs" -a "$SUBCOM" == "attach" ]; then
	if [ "$1" = -n ] || [ "$1" = --name ]
	then
		ECSAttachVolumeName "$2" "$3"
	else
		ECSAttachVolumeId   "$1" "$2"
	fi
elif [ "$MAINCOM" == "evs" -a "$SUBCOM" == "detach" ]; then
	if [ "$1" = -n ] || [ "$1" = --name ]
	then
		ECSDetachVolumeName "$2" "$3"
	else
		ECSDetachVolumeId   "$1" "$2"
	fi

elif [ "$MAINCOM" == "backuppolicy" -a "$SUBCOM" == "list" ]; then
	getBackupPolicyList
elif [ "$MAINCOM" == "backuppolicy" -a "$SUBCOM" == "show" ]; then
	getBackupPolicyDetail "$1"
elif [ "$MAINCOM" == "backuppolicy" -a "$SUBCOM" == "create" ]; then
	createBackupPolicy "$@"
elif [ "$MAINCOM" == "backuppolicy" -a "$SUBCOM" == "update" ]; then
	updateBackupPolicy "$@"
elif [ "$MAINCOM" == "backuppolicy" -a "$SUBCOM" == "delete" ]; then
	deleteBackupPolicy "$1"
elif [ "$MAINCOM" == "backuppolicy" -a "$SUBCOM" == "add" ]; then
	addVolsToPolicy "$@"
elif [ "$MAINCOM" == "backuppolicy" -a "$SUBCOM" == "remove" ]; then
	rmvVolsFromPolicy "$@"
elif [ "$MAINCOM" == "backuppolicy" -a "$SUBCOM" == "execute" ]; then
	executeBackupPolicy "$1"
elif [ "$MAINCOM" == "backuppolicy" -a "$SUBCOM" == "showtasks" ]; then
	showBackupPolicyTasks "$1"
elif [ "$MAINCOM" == "backuppolicy" -a "$SUBCOM" == "listtasks" ]; then
	listBackupPolicyTasks "$1"

elif [ "$MAINCOM" == "backup" -a "$SUBCOM" == "help" ]; then
	backupHelp
elif [ "$MAINCOM" == "backup" -a "$SUBCOM" == "list" ]; then
	getBackupList "$@"
elif [ "$MAINCOM" == "backup" -a "$SUBCOM" == "show" ]; then
	getBackupDetail "$1"
elif [ "$MAINCOM" == "backup" -a "$SUBCOM" == "delete" ]; then
	deleteBackupOTC "$1"
elif [ "$MAINCOM" == "backup" -a "$SUBCOM" == "delete_" ]; then
	deleteBackup "$1"
elif [ "$MAINCOM" == "backup" -a "$SUBCOM" == "create" ] ||
     [ "$MAINCOM" == "backup" -a "$SUBCOM" == "backup" ] ; then
	createBackup "$@"
elif [ "$MAINCOM" == "backup" -a "$SUBCOM" == "restore" ]; then
	restoreBackup "$@"
elif [ "$MAINCOM" == "snapshot" -a "$SUBCOM" == "list" ]; then
	getSnapshotList "$@"
elif [ "$MAINCOM" == "snapshot" -a "$SUBCOM" == "show" ]; then
	getSnapshotDetail "$1"
elif [ "$MAINCOM" == "snapshot" -a "$SUBCOM" == "delete" ]; then
	deleteSnapshot "$1"

elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "help" ] ||
     [ "$MAINCOM" == "ulb" -a "$SUBCOM" == "help" ]; then
	elbHelp
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "list" ]; then
	getELBList
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "show" ]; then
	getELBDetail $1
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "delete" ]; then
	deleteELB $1
	echo "$ELBJOBID"
	WaitForTask $ELBJOBID 2
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "create" ]; then
	createELB "$@"
	echo "$ELBJOBID"
	#WaitForTask $ELBJOBID 2
	WaitForTaskFieldOpt $ELBJOBID .entities.elb.id

elif [ "$MAINCOM" == "elb" -a "${SUBCOM:0:12}" == "listlistener" ]; then
	getListenerList "$@"
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "showlistener" ]; then
	getListenerDetail "$@"
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "createlistener" ] ||
     [ "$MAINCOM" == "elb" -a "$SUBCOM" == "addlistener" ]; then
	createListener "$@"
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "dellistener" ]; then
	deleteListener "$@"
elif [ "$MAINCOM" == "elb" -a "${SUBCOM:0:10}" == "listmember" ]; then
	getMemberList "$@"
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "showmember" ]; then
	getMemberDetail "$@"
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "addmember" ]; then
	createMember "$@"
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "delmember" ]; then
	deleteMember "$@"
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "showcheck" ]; then
	getCheck "$@"
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "addcheck" ]; then
	createCheck "$@"
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "delcheck" ]; then
	deleteCheck "$@"
elif [ "$MAINCOM" == "elb" -a "${SUBCOM:0:8}" == "listcert" ]; then
	listELBCert
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "showcert" ]; then
	showELBCert "$@"
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "createcert" ]; then
	createELBCert "$@"
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "updatecert" ]; then
	modifyELBCert "$@"
elif [ "$MAINCOM" == "elb" -a "$SUBCOM" == "delcert" ] ||
     [ "$MAINCOM" == "elb" -a "$SUBCOM" == "deletecert" ]; then
	deleteELBCert "$@"

elif [ "$MAINCOM" == "ulb" -a "$SUBCOM" == "list" ]; then
	getULBList
elif [ "$MAINCOM" == "ulb" -a "$SUBCOM" == "show" ]; then
	getULBDetail "$@"
elif [ "$MAINCOM" == "ulb" -a "$SUBCOM" == "details" ]; then
	getULBFullDetail "$@"

elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "help" ]; then
	rdsHelp
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "list" ] ||
     [ "$MAINCOM" == "rds" -a "$SUBCOM" == "listinstances" ]; then
	getRDSInstanceList
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "show" ] ||
     [ "$MAINCOM" == "rds" -a "$SUBCOM" == "showinstances" ]; then
	getRDSInstanceDetails "$@"
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "apis" ] ||
     [ "$MAINCOM" == "rds" -a "$SUBCOM" == "listapis" ]; then
	getRDSAPIVersionList
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "showapi" ]; then
	getRDSAPIDetails "$@"
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "datastore" ] ||
     [ "$MAINCOM" == "rds" -a "$SUBCOM" == "showdatastore" ]; then
	getRDSDatastoreDetails "$@"
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "showdatastoreparameters" ]; then
	getRDSDatastoreParameters "$@"
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "showdatastoreparameter" ]; then
	getRDSDatastoreParameter "$@"
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "flavors" ] ||
     [ "$MAINCOM" == "rds" -a "$SUBCOM" == "listflavors" ]; then
	getRDSFlavorList "$@"
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "showflavor" ]; then
	getRDSFlavorDetails "$@"
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "create" ]; then
	createRDSInstance "$@"
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "delete" ]; then
	deleteRDSInstance "$@"
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "showbackuppolicy" ]; then
	getRDSInstanceBackupPolicy "$@"
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "listsnapshots" ] ||
     [ "$MAINCOM" == "rds" -a "$SUBCOM" == "listbackups" ]; then
	getRDSSnapshots
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "showerrors" ]; then
	getRDSErrorLogs "$@"
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "showslowstatements" ] ||
     [ "$MAINCOM" == "rds" -a "$SUBCOM" == "showslowqueries" ]; then
	getRDSSlowStatementLogs "$@"
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "createsnapshot" ] ||
     [ "$MAINCOM" == "rds" -a "$SUBCOM" == "createbackup" ]; then
	createRDSSnapshot "$@"
elif [ "$MAINCOM" == "rds" -a "$SUBCOM" == "deletesnapshot" ] ||
     [ "$MAINCOM" == "rds" -a "$SUBCOM" == "deletebackup" ]; then
	deleteRDSSnapshot "$@"

elif [ "$MAINCOM" == "domain" -a "$SUBCOM" == "help" ]; then
	dnsHelp
elif [ "$MAINCOM" == "domain" -a "$SUBCOM" == "list" ]; then
	listDomains
elif [ "$MAINCOM" == "domain" -a "$SUBCOM" == "create" ]; then
	createDomain "$@"
elif [ "$MAINCOM" == "domain" -a "$SUBCOM" == "show" ]; then
	showDomain "$1"
elif [ "$MAINCOM" == "domain" -a "$SUBCOM" == "delete" ]; then
	deleteDomain "$1"
elif [ "$MAINCOM" == "domain" -a "$SUBCOM" == "listrecords" ]; then
	listRecords "$1"
elif [ "$MAINCOM" == "domain" -a "$SUBCOM" == "showrecord" ]; then
	showRecord "$@"
elif [ "$MAINCOM" == "domain" -a "$SUBCOM" == "delrecord" ]; then
	deleteRecord "$@"
elif [ "$MAINCOM" == "domain" -a "$SUBCOM" == "addrecord" ]; then
	addRecord "$@"
elif [ "$MAINCOM" == "domain" -a "$SUBCOM" == "associate" ]; then
	associateDomain "$@"
elif [ "$MAINCOM" == "domain" -a "$SUBCOM" == "dissociate" ] ||
      [ "$MAINCOM" == "domain" -a "$SUBCOM" == "disassociate" ]; then
	dissociateDomain "$@"

elif [ "$MAINCOM" == "cluster" -a "$SUBCOM" == "help" ]; then
	cceHelp
elif [ "$MAINCOM" == "cluster" -a "$SUBCOM" == "list" ]; then
	shortlistClusters
elif [ "$MAINCOM" == "cluster" -a "$SUBCOM" == "list-detail" ] ||
     [ "$MAINCOM" == "cluster" -a "$SUBCOM" == "details" ]; then
	listClusters
elif [ "$MAINCOM" == "cluster" -a "$SUBCOM" == "show" ]; then
	showCluster "$@"
elif [ "$MAINCOM" == "cluster" -a "$SUBCOM" == "create" ]; then
	createCluster "$@"
elif [ "$MAINCOM" == "cluster" -a "$SUBCOM" == "delete" ]; then
	deleteCluster "$1"
elif [ "$MAINCOM" == "host" -a "$SUBCOM" == "list" ]; then
	listClusterHosts "$@"
elif [ "$MAINCOM" == "host" -a "$SUBCOM" == "show" ]; then
	showClusterHost "$@"
elif [ "$MAINCOM" == "host" -a "$SUBCOM" == "create" ]; then
	createClusterHosts "$@"
elif [ "$MAINCOM" == "host" -a "$SUBCOM" == "delete" ]; then
	deleteClusterHosts "$@"

elif [ "$MAINCOM" == "metrics" -a "$SUBCOM" == "help" ]; then
	cesHelp
elif [ "$MAINCOM" == "metrics" -a "$SUBCOM" == "list" ]; then
	listMetrics "$@"
elif [ "$MAINCOM" == "metrics" -a "$SUBCOM" == "favorites" ]; then
	listFavMetrics
elif [ "$MAINCOM" == "metrics" -a "$SUBCOM" == "show" ]; then
	showMetrics "$@"
elif [ "$MAINCOM" == "alarms" -a "$SUBCOM" == "list" ]; then
	listAlarms
elif [ "$MAINCOM" == "alarms" -a "$SUBCOM" == "show" ]; then
	showAlarms "$1"
elif [ "$MAINCOM" == "alarms" -a "$SUBCOM" == "limits" ]; then
	showAlarmsQuotas
elif [ "$MAINCOM" == "alarms" -a "$SUBCOM" == "disable" ]; then
	AlarmsAction "false" "$1"
elif [ "$MAINCOM" == "alarms" -a "$SUBCOM" == "enable" ]; then
	AlarmsAction "true" "$1"
elif [ "$MAINCOM" == "alarms" -a "$SUBCOM" == "delete" ]; then
	deleteAlarms "$1"

elif [ "$MAINCOM" == "stack" -a "$SUBCOM" == "help" ]; then
	heatHelp
elif [ "$MAINCOM" == "stack" -a "$SUBCOM" == "list" ]; then
	listStacks
elif [ "$MAINCOM" == "stack" -a "$SUBCOM" == "show" ]; then
	showStack "$1"
elif [ "$MAINCOM" == "stack" -a "$SUBCOM" == "snapshots" ]; then
	listStackSnapshots "$1"
elif [ "$MAINCOM" == "stack" -a "$SUBCOM" == "resources" ]; then
	listStackResources "$1"
elif [ "$MAINCOM" == "stack" -a "$SUBCOM" == "showresource" ]; then
	showStackResource "$1" "$2"
elif [ "$MAINCOM" == "stack" -a "$SUBCOM" == "events" ]; then
	listStackEvents "$1"
elif [ "$MAINCOM" == "stack" -a "$SUBCOM" == "template" ]; then
	showStackTemplate "$1"
elif [ "$MAINCOM" == "stack" -a "$SUBCOM" == "resourcetypes" ]; then
	listStackResTypes
elif [ "$MAINCOM" == "stack" -a "$SUBCOM" == "buildinfo" ]; then
	showStackBuildInfo
elif [ "$MAINCOM" == "stack" -a "$SUBCOM" == "deployments" ]; then
	listStackDeployments
elif [ "$MAINCOM" == "stack" -a "$SUBCOM" == "showdeployment" ]; then
	showStackDeployment "$1"

elif [ "$MAINCOM" == "trace" -a "$SUBCOM" == "help" ]; then
	otcnewHelp
elif [ "$MAINCOM" == "trace" -a "$SUBCOM" == "list" ]; then
	listTrackers

### RLSH 2017-10-06 #########################################################
elif [ "$MAINCOM" == "trace" -a "$SUBCOM" == "show" ]; then
	listTraces $1
#############################################################################

elif [ "$MAINCOM" == "queues" -a "$SUBCOM" == "help" ]; then
	dmsHelp
elif [ "$MAINCOM" == "queues" -a "$SUBCOM" == "list" ]; then
	listQueues
elif [ "$MAINCOM" == "queues" -a "$SUBCOM" == "show" ]; then
	showQueue $1
elif [ "$MAINCOM" == "queues" -a "$SUBCOM" == "create" ]; then
	createQueue "$@"
elif [ "$MAINCOM" == "queues" -a "$SUBCOM" == "delete" ]; then
	deleteQueue $1
elif [ "$MAINCOM" == "queues" -a "$SUBCOM" == "limits" ]; then
	queueLimits

elif [ "$MAINCOM" == "queues" -a "$SUBCOM" == "consumers" ] ||
     [ "$MAINCOM" == "queues" -a "$SUBCOM" == "listconsumer" ] ||
     [ "$MAINCOM" == "consumer" -a "$SUBCOM" == "list" ]; then
	listConsumerGroups $1
#elif [ "$MAINCOM" == "queues" -a "$SUBCOM" == "showconsumer" ]; then
#	showQueue $1
elif [ "$MAINCOM" == "queues" -a "$SUBCOM" == "createconsumer" ] ||
     [ "$MAINCOM" == "consumer" -a "$SUBCOM" == "create" ]; then
	createConsumerGroup "$@"
elif [ "$MAINCOM" == "queues" -a "$SUBCOM" == "deleteconsumer" ] ||
     [ "$MAINCOM" == "consumer" -a "$SUBCOM" == "delete" ]; then
	deleteConsumerGroup "$@"

elif [ "$MAINCOM" == "queues" -a "$SUBCOM" == "queuemsg" ]; then
	queueMessage "$@"
elif [ "$MAINCOM" == "queues" -a "$SUBCOM" == "getmsg" ]; then
	getMessage "$@"
elif [ "$MAINCOM" == "queues" -a "$SUBCOM" == "ackmsg" ]; then
	ackMessage "$@"


elif [ "$MAINCOM" == "notifications" -a "$SUBCOM" == "help" ]; then
	smnHelp
elif [ "$MAINCOM" == "notifications" -a "$SUBCOM" == "list" ]; then
	listTopics
elif [ "$MAINCOM" == "notifications" -a "$SUBCOM" == "show" ]; then
	showTopic "$1"
elif [ "$MAINCOM" == "notifications" -a "$SUBCOM" == "create" ]; then
	createTopic "$@"
elif [ "$MAINCOM" == "notifications" -a "$SUBCOM" == "delete" ]; then
	deleteTopic "$1"
elif [ "$MAINCOM" == "notifications" -a "$SUBCOM" == "subscriptions" ]; then
	listSubscriptions "$1"
elif [ "$MAINCOM" == "notifications" -a "$SUBCOM" == "subscribe" ]; then
	addSubscription "$@"
elif [ "$MAINCOM" == "notifications" -a "$SUBCOM" == "unsubscribe" ]; then
	deleteSubscription "$1"
elif [ "$MAINCOM" == "notifications" -a "$SUBCOM" == "publish" ]; then
	publishNotification "$@"
elif [ "$MAINCOM" == "notifications" -a "$SUBCOM" == "SMS" ]; then
	sendSMS "$@"

elif [ "$MAINCOM" == "antiddos"  -a "$SUBCOM" == "list" ]; then
	listAntiDDoS
elif [ "$MAINCOM" == "shares"  -a "$SUBCOM" == "list" ]; then
	listShares
elif [ "$MAINCOM" == "shares"  -a "$SUBCOM" == "show" ]; then
	showShare "$@"
elif [ "$MAINCOM" == "tags"  -a "$SUBCOM" == "list" ]; then
	listTags
elif [ "$MAINCOM" == "tags"  -a "$SUBCOM" == "help" ]; then
	tagHelp
elif [ "$MAINCOM" == "tags"  -a "$SUBCOM" == "create" ]; then
	createTags "$@"
elif [ "$MAINCOM" == "tags"  -a "$SUBCOM" == "delete" ]; then
	deleteTags "$@"
elif [ "$MAINCOM" == "cache"  -a "$SUBCOM" == "list" ]; then
	listCaches
elif [ "$MAINCOM" == "cache"  -a "$SUBCOM" == "products" ]; then
	listCacheProducts
elif [ "$MAINCOM" == "cache"  -a "$SUBCOM" == "azs" ]; then
	listCacheAZs
elif [ "$MAINCOM" == "dws"  -a "$SUBCOM" == "list" ]; then
	listDWS
elif [ "$MAINCOM" == "serverbackup"  -a "$SUBCOM" == "list" ]; then
	listServerBackups
elif [ "$MAINCOM" == "migration"  -a "$SUBCOM" == "list" ]; then
	listMigrations
elif [ "$MAINCOM" == "kms"  -a "$SUBCOM" == "list" ]; then
	listKMS
elif [ "$MAINCOM" == "vpn"  -a "$SUBCOM" == "list" ]; then
	listVPN
elif [ "$MAINCOM" == "fw"  -a "$SUBCOM" == "list" ]; then
	listFWRules
elif [ "$MAINCOM" == "mrs"  -a "$SUBCOM" == "help" ]; then
	otcnewHelp
elif [ "$MAINCOM" == "mrs"  -a "$SUBCOM" == "clusterlist" -o "$SUBCOM" == "listclusters" ]; then
	listMRSClusters
elif [ "$MAINCOM" == "mrs"  -a "$SUBCOM" == "joblist" -o "$SUBCOM" == "listjobs" ]; then
	listMRSJobs
elif [ "$MAINCOM" == "mrs"  -a "$SUBCOM" == "job" -o "$SUBCOM" == "showjob" ]; then
	showMRSJob $1

elif [ "$MAINCOM" == "deh" -a "$SUBCOM" == "help" ]; then
	dehHelp
elif [ "$MAINCOM" == "deh" -a "$SUBCOM" == "list" ]; then
	listDEH
elif [ "$MAINCOM" == "deh" -a "$SUBCOM" == "show" ]; then
	showDEH "$1"
elif [ "$MAINCOM" == "deh" -a "${SUBCOM:0:6}" == "listvm" ]; then
	listDEHservers "$1"
elif [ "$MAINCOM" == "deh" -a "${SUBCOM:0:8}" == "listtype" ]; then
	listDEHtypes "$1"
elif [ "$MAINCOM" == "deh" -a "$SUBCOM" == "create" ]; then
	createDEH "$@"
elif [ "$MAINCOM" == "deh" -a "$SUBCOM" == "delete" ]; then
	deleteDEH "$1"

elif [ "$MAINCOM" == "workspace" -a "$SUBCOM" == "help" ]; then
	workspaceHelp
elif [ "$MAINCOM" == "workspace" -a "$SUBCOM" == "query" ]; then
	queryWorkspace
elif [ "$MAINCOM" == "workspace" -a "$SUBCOM" == "apply" ]; then
	applyWorkspace
elif [ "$MAINCOM" == "workspace" -a "$SUBCOM" == "cancel" ]; then
	cancelWorkspace

elif [ "$MAINCOM" == "workspace-job" -a "$SUBCOM" == "help" ]; then
	workspaceJobHelp
elif [ "$MAINCOM" == "workspace-job" -a "$SUBCOM" == "show" ]; then
	getWorkspaceJobList $1
	echo "$WORKSPACEJOBSTATUSJSON"
elif [ "$MAINCOM" == "workspace-job" -a "$SUBCOM" == "wait" ]; then
	WaitForWorkspaceJob

elif [ "$MAINCOM" == "workspace-desktop" -a "$SUBCOM" == "help" ]; then
	workspaceDesktopHelp
elif [ "$MAINCOM" == "workspace-desktop" -a "$SUBCOM" == "list" ]; then
	listWorkspaceDesktops

elif [ "$MAINCOM" == "workspace-product" -a "$SUBCOM" == "help" ]; then
	workspaceProductHelp
elif [ "$MAINCOM" == "workspace-product" -a "$SUBCOM" == "list" ]; then
	listWorkspaceProducts

elif [ "$MAINCOM" == "mds" -a "$SUBCOM" == "help" ]; then
	mdsHelp
elif [ "$MAINCOM" == "mds" -a "$SUBCOM" == "meta_data" ]; then
	getMeta meta_data.json "$@"
elif [ "$MAINCOM" == "mds" -a "$SUBCOM" == "vendor_data" ]; then
	getMeta vendor_data.json "$@"
elif [ "$MAINCOM" == "mds" -a "$SUBCOM" == "network_data" ]; then
	getMeta network_data.json "$@"
elif [ "$MAINCOM" == "mds" -a "$SUBCOM" == "user_data" ]; then
	getMeta user_data "$@"
elif [ "$MAINCOM" == "mds" -a "$SUBCOM" == "password" ]; then
	getMeta password "$@"

elif [ "$MAINCOM" == "nat" -a "$SUBCOM" == "help" ]   ||
     [ "$MAINCOM" == "dcaas" -a "$SUBCOM" == "help" ] ||
     [ "$MAINCOM" == "dis" -a "$SUBCOM" == "help" ]   ||
     [ "$MAINCOM" == "products" -a "$SUBCOM" == "help" ]; then
	otcnew3Help
elif [ "$MAINCOM" == "nat" -a "$SUBCOM" == "list" ]; then
	listNATGW "$@"
elif [ "$MAINCOM" == "nat" -a "$SUBCOM" == "rules" ]; then
	listNATRules "$@"
elif [ "$MAINCOM" == "dcaas" -a "$SUBCOM" == "list" ] ||
     [ "$MAINCOM" == "dcaas" -a "$SUBCOM" == "connections" ]; then
	listDCAASConn "$@"
elif [ "$MAINCOM" == "dcaas" -a "$SUBCOM" == "gateways" ]; then
	listDCAASVGW "$@"
elif [ "$MAINCOM" == "dcaas" -a "$SUBCOM" == "interfaces" ]; then
	listDCAASVIF "$@"
elif [ "$MAINCOM" == "dcaas" -a "$SUBCOM" == "endpoints" ]; then
	listDCAASEPGrp "$@"
elif [ "$MAINCOM" == "dis" -a "$SUBCOM" == "list" ]; then
	listDIS "$@"
elif [ "$MAINCOM" == "products" -a "$SUBCOM" == "categories" ]; then
	listProductCats "$@"

elif [ "$MAINCOM" == "asgroup" -a "$SUBCOM" == "help" ]; then
	asHelp
elif [ "$MAINCOM" == "asgroup" -a "$SUBCOM" == "list" ]; then
	listASGroup "$@"
elif [ "$MAINCOM" == "asgroup" -a "$SUBCOM" == "show" ]; then
	showASGroup "$@"
elif [ "$MAINCOM" == "asgroup" -a "$SUBCOM" == "vms" ]; then
	listASGroupVMs "$@"
elif [ "$MAINCOM" == "asgroup" -a "$SUBCOM" == "log" ]; then
	getASGroupLog "$@"
elif [ "$MAINCOM" == "asconfig" -a "$SUBCOM" == "list" ]; then
	listASConfig "$@"
elif [ "$MAINCOM" == "asconfig" -a "$SUBCOM" == "show" ]; then
	showASConfig "$@"
elif [ "$MAINCOM" == "aspolicy" -a "$SUBCOM" == "list" ]; then
	listASPolicy "$@"
elif [ "$MAINCOM" == "aspolicy" -a "$SUBCOM" == "show" ]; then
	showASPolicy "$@"
elif [ "$MAINCOM" == "asgroup" -a "$SUBCOM" == "limits" ]; then
	getASQuota "$@"
elif [ "$MAINCOM" == "asgroup" -a "$SUBCOM" == "tags" ]; then
	listASTags "$@"

elif [ "$MAINCOM" == "custom" -a "$SUBCOM" == "help" ]; then
	customHelp
elif [ "$MAINCOM" == "custom" ]; then
	handleCustom "$SUBCOM" "$@"
else
	if [ "$MAINCOM" != "help" ]; then
		echo "ERROR: Could not parse $MAINCOM $SUBCOM" 1>&2
	fi
	printHelp
fi

# Collect status for pieces that might have been performed in MAIN
RC=$?
if test $RC == 0 -a -n "$ERR"; then RC=$ERR; fi
if test $RC == 0 -a -n "${PIPESTATUS[0]}"; then RC=${PIPESTATUS[0]}; fi
exit $RC
