#!/usr/bin/env bash

# Original script came from the Box Anemometer github repo

# anemometer collection script to gather and digest slow query logs
# this is a quick draft script so please give feedback!
#
# basic usage would be to add this to cron like this:
# */5 * * * * anemometer_collect.sh --interval 15 --history-db-host anemometer-db.example.com
#
# This will have to run as a user which has write privileges to the mysql slow log
#
# Additionally there are two sets of permissions to worry about:  The local mysql instance, and the remote digest storage instance
# These are handled through defaults files, just create a file in the: my.cnf format such as:
# [client]
# user=
# password=
#
# use --defaults-file for permissions to the local mysql instance
# and use --history-defaults-file for permissions to the remote digest storage instance
#
#

#
# vars not configurable through commandline args
#
digest='/usr/local/bin/pt-query-digest'

#
# vars for anemometer system; configurable with sane defaults
#
history_db_host=anemometer-mysql
history_db_port=3306
history_db_name='slow_query_log'
history_defaults_file=/tmp/anem_mysql.cnf

# The location on the db server and locally where we write the temp file
temp_slow_log_file=/tmp/tmp_slow_log

# controls for how long and how much of the slow queries we log
interval=30
rate=

#
# vars for target MySQL system; must be configured through command line args
#
defaults_file=               # e.g. db_host.cnf
port=                        # e.g. 3306 -- could also be in defaults_file
msyql_host=                  # e.g. srv-110-34.720.rdio -- could also be in defaults_file

# system user that can ssh into the mysql_host
ssh_user=                    # e.g. mysqlwatcher
identity_file=               # e.g. id_rsa

#
# vars set internally in this script
#

# options when talking to target MySQL server
mysqlopts=

help () {
	cat <<EOF

Usage: $0 --defaults-file <filename> --ssh-user <username> --identity-file <filename>

Required Options:
    --defaults-file -f       The defaults file to use for the client
    --ssh-user -u            username to ssh to the mysql box for copying the slow log out
    --identity-file -s       The keypair file that the user has auth'd for ssh access

Options:
    --interval -i            The collection duration
    --rate -r                Set log_slow_rate_limit (For Percona MySQL Only)
    --temp-log-file -t       The location on the db server, and locally, where we will write the temp log file

    --history-db-host        Hostname of anemometer database server
    --history-db-port        Port of anemometer database server
    --history-db-name        Database name of anemometer database server (Default slow_query_log)
    --history-defaults-file  Defaults file to pass to pt-query-digest for connecting to the remote anemometer database
EOF
}

while test $# -gt 0
do
    case $1 in
        --defaults-file|-f)
            defaults_file=$2
            shift
            ;;
	      --ssh-user|-u)
	          ssh_user=$2
	          shift
	          ;;
        --identity-file|-s)
            identity_file=$2
            shift
            ;;
        --port|-p)
            port=$2
            shift
            ;;
        --mysql-host|-h)
            mysql_host=$2
            shift
            ;;
        --interval|-i)
            interval=$2
            shift
            ;;
	      --rate|-r)
	          rate=$2
	          shift
	          ;;
	      --temp-log-file|-t)
	          temp_slow_log_file=$2
	          shift
	          ;;
	      --history-db-host)
	          history_db_host=$2
	          shift
	          ;;
        --history-db-port)
            history_db_port=$2
	          shift
	          ;;
	      --history-db-name)
	          history_db_name=$2
	          shift
	          ;;
	      --history-defaults-file)
	          history_defaults_file=$2
	          shift
	          ;;
	      --help)
	          help
	          exit 0
	          ;;
        *)
            echo >&2 "Invalid argument: $1"
            ;;
    esac
    shift
done

# verify the pt-query-digest script is installed
if [ ! -e "${digest}" ];
then
	echo "Error: cannot find digest script at: ${digest}"
	exit 1
fi

echo "Found the digest script at: ${digest}"

# set the defaults file, if it exists, to mysqlopts
if [ ! -z "${defaults_file}" ];
then
	mysqlopts="--defaults-file=${defaults_file}"
fi

if [ ! -z "${mysql_host}" ];
then
	mysqlopts="${mysqlopts} --host=${mysql_host}"
fi

if [ ! -z "${port}" ];
then
	mysqlopts="${mysqlopts} --port=${port}"
fi

echo "Configured mysqlopts: ${mysqlopts}"

# apply the settings for the slow log querying
if [ ! -z "${rate}" ];
then
  log_slow_rate_limit_orig=$(mysql ${mysqlopts} -N -B -e "select @@global.log_slow_rate_limit;")
  mysql ${mysqlopts} -e "SET GLOBAL log_slow_rate_limit=${rate}"
fi

slow_query_log_orig=$(mysql ${mysqlopts} -N -B -e "select @@global.slow_query_log;")
slow_query_log_file_orig=$(mysql ${mysqlopts} -N -B -e "select @@global.slow_query_log_file;")
long_query_time_orig=$(mysql ${mysqlopts} -N -B -e "select @@global.long_query_time;")

echo "Captured old values of slow query log settings; setting to new values for capture."

mysql ${mysqlopts} -e "SET @@global.slow_query_log_file='${temp_slow_log_file}'"
if [ $? -ne 0 ];
then
  echo "Error: cannot set slow log file. Aborting"
  exit 1
fi 

mysql ${mysqlopts} -e "SET @@global.long_query_time=0.00"
if [ $? -ne 0 ];
then
  echo "Error: cannot change long_query_time. Aborting"
  exit 1
fi

mysql ${mysqlopts} -e "SET @@global.slow_query_log=1"
if [ $? -ne 0 ];
then
  echo "Error: cannot enable slow log. Aborting"
  exit 1
fi 

echo "Done setting new values; collection has begun."

# gather some slow log data
echo "Slow log enabled; sleeping for ${interval} seconds"
sleep "${interval}"

echo "Done collecting log information to: ${temp_log_file} on the db server."

# reset the slow log variables to original values
if [ ! -z "${rate}" ];
then
	mysql ${mysqlopts} -e "SET GLOBAL log_slow_rate_limit=${log_slow_rate_limit_orig}"
fi
mysql ${mysqlopts} -e "SET @@global.slow_query_log=${slow_query_log_orig}"
mysql ${mysqlopts} -e "SET @@global.long_query_time=${long_query_time_orig}"
mysql ${mysqlopts} -e "SET @@global.slow_query_log_file='${slow_query_log_file_orig}'"

echo "Done re-setting to old values of slow query log settings."

# copy the log to a tmp location
# check that we have a host defined
if [ -z "${mysql_host}" ];
then
  mysql_host=`cat ${defaults_file} | awk '/host/ {print}' | sed s/host=//`
fi

echo "Copying remote log file from: ${ssh_user}@${mysql_host}:${temp_slow_log_file} to: ${history_db_host}:${history_db_port}/${history_db_name}"

scp -o "StrictHostKeyChecking no" -i "$identity_file" "$ssh_user@$mysql_host:${temp_slow_log_file}" ${temp_slow_log_file}
if [[ ! -e "${temp_slow_log_file}" ]]
then
	echo "No slow log to process";
	exit
fi

echo "Done copying file; checking for history defaults file."

# if we have a defaults file for anem-mysql use that
if [ ! -z "${history_defaults_file}" ];
then
	pass_opt="--defaults-file=${history_defaults_file}"
fi

echo "Done setting defaults to ${pass_opt}."

echo "Processing log."

# process the log, causing it to dump into the mysql database
"${digest}" ${pass_opt} \
  --review h="${history_db_host}",D="${history_db_name}",t=global_query_review \
  --history h="${history_db_host}",D="${history_db_name}",t=global_query_review_history \
  --no-report --limit=0\% \
  --filter="\$event->{Bytes} = length(\$event->{arg}) and \$event->{hostname} = \"${mysql_host}\" " \
  "/tmp/tmp_slow_log"

echo "Completed processing the slow query log file; clearing the remote temp file."

# clear the tmp slow log
ssh -i ${identity_file} ${ssh_user}@${mysql_host} "cat /dev/null > /tmp/tmp_slow_log"

echo "Done. Slow query log file analysis complete."
