#!/usr/bin/env bash
sshd_idle_timeout_value="900"

function replace_or_append {
  local config_file=$1
  local key=$2
  local value=$3
  local cce=$4
  local format=$5

  # Check sanity of the input
  if [ $# -lt "3" ]
  then
        echo "Usage: replace_or_append 'config_file_location' 'key_to_search' 'new_value'"
        echo
        echo "If symlinks need to be taken into account, add yes/no to the last argument"
        echo "to allow to 'follow_symlinks'."
        echo "Aborting."
        exit 1
  fi

  # Test if the config_file is a symbolic link. If so, use --follow-symlinks with sed.
  # Otherwise, regular sed command will do.
  if test -L $config_file; then
    sed_command="sed -i --follow-symlinks"
  else
    sed_command="sed -i"
  fi

  # Test that the cce arg is not empty or does not equal CCENUM.
  # If CCENUM exists, it means that there is no CCE assigned.
  if ! [ "x$cce" = x ] && [ "$cce" != 'CCENUM' ]; then
    cce="CCE-${cce}"
  else
    cce="CCE"
  fi

  # Strip any search characters in the key arg so that the key can be replaced without
  # adding any search characters to the config file.
  stripped_key=$(sed "s/[\^=\$,;+]*//g" <<< $key)

  # If there is no print format specified in the last arg, use the default format.
  if ! [ "x$format" = x ] ; then
    printf -v formatted_output "$format" $stripped_key $value
  else
    formatted_output="$stripped_key = $value"
  fi

  # If the key exists, change it. Otherwise, add it to the config_file.
  if `grep -qi $key $config_file` ; then
    $sed_command "s/$key.*/$formatted_output/g" $config_file
  else
    echo -ne "\n# Per $cce: Set $formatted_output in $config_file" >> $config_file
    echo -ne "\n$formatted_output" >> $config_file
  fi

}

replace_or_append '/etc/ssh/sshd_config' '^ClientAliveInterval' $sshd_idle_timeout_value 'CCENUM' '%s %s'