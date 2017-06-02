#!/usr/bin/env bash

# First perform the remediation of the syscall rule
# Retrieve hardware architecture of the underlying system
[ $(getconf LONG_BIT) = "32" ] && RULE_ARCHS=("b32") || RULE_ARCHS=("b32" "b64")

for ARCH in "${RULE_ARCHS[@]}"
do
	PATTERN="-a always,exit -F arch=$ARCH -S .* -k *"
	# Use escaped BRE regex to specify rule group
	GROUP="set\(host\|domain\)name"
	FULL_RULE="-a always,exit -F arch=$ARCH -S sethostname -S setdomainname -k audit_rules_networkconfig_modification"
	# Perform the remediation for both possible tools: 'auditctl' and 'augenrules'

function fix_audit_syscall_rule {

# Load function arguments into local variables
local tool="$1"
local pattern="$2"
local group="$3"
local arch="$4"
local full_rule="$5"

# Check sanity of the input
if [ $# -ne "5" ]
then
        echo "Usage: fix_audit_syscall_rule 'tool' 'pattern' 'group' 'arch' 'full rule'"
        echo "Aborting."
        exit 1
fi

# Create a list of audit *.rules files that should be inspected for presence and correctness
# of a particular audit rule. The scheme is as follows:
#
# -----------------------------------------------------------------------------------------
#  Tool used to load audit rules | Rule already defined  |  Audit rules file to inspect    |
# -----------------------------------------------------------------------------------------
#        auditctl                |     Doesn't matter    |  /etc/audit/audit.rules         |
# -----------------------------------------------------------------------------------------
#        augenrules              |          Yes          |  /etc/audit/rules.d/*.rules     |
#        augenrules              |          No           |  /etc/audit/rules.d/$key.rules  |
# -----------------------------------------------------------------------------------------
#
declare -a files_to_inspect

# First check sanity of the specified audit tool
if [ "$tool" != 'auditctl' ] && [ "$tool" != 'augenrules' ]
then
        echo "Unknown audit rules loading tool: $1. Aborting."
        echo "Use either 'auditctl' or 'augenrules'!"
        exit 1
# If audit tool is 'auditctl', then add '/etc/audit/audit.rules'
# file to the list of files to be inspected
elif [ "$tool" == 'auditctl' ]
then
        files_to_inspect=("${files_to_inspect[@]}" '/etc/audit/audit.rules' )
# If audit tool is 'augenrules', then check if the audit rule is defined
# If rule is defined, add '/etc/audit/rules.d/*.rules' to the list for inspection
# If rule isn't defined yet, add '/etc/audit/rules.d/$key.rules' to the list for inspection
elif [ "$tool" == 'augenrules' ]
then
        # Extract audit $key from audit rule so we can use it later
        key=$(expr "$full_rule" : '.*-k[[:space:]]\([^[:space:]]\+\)')
        # Check if particular audit rule is already defined
        IFS=$'\n' matches=($(sed -s -n -e "/${pattern}/!d" -e "/${arch}/!d" -e "/${group}/!d;F" /etc/audit/rules.d/*.rules))
        # Reset IFS back to default
        unset $IFS
        for match in "${matches[@]}"
        do
                files_to_inspect=("${files_to_inspect[@]}" "${match}")
        done
        # Case when particular rule isn't defined in /etc/audit/rules.d/*.rules yet
        if [ ${#files_to_inspect[@]} -eq "0" ]
        then
                files_to_inspect="/etc/audit/rules.d/$key.rules"
                if [ ! -e "$files_to_inspect" ]
                then
                        touch "$files_to_inspect"
                        chmod 0640 "$files_to_inspect"
                fi
        fi
fi

#
# Indicator that we want to append $full_rule into $audit_file by default
local append_expected_rule=0

for audit_file in "${files_to_inspect[@]}"
do

        # Filter existing $audit_file rules' definitions to select those that:
        # * follow the rule pattern, and
        # * meet the hardware architecture requirement, and
        # * are current syscall group specific
        IFS=$'\n' existing_rules=($(sed -e "/${pattern}/!d" -e "/${arch}/!d" -e "/${group}/!d"  "$audit_file"))
        # Reset IFS back to default
        unset $IFS

        # Process rules found case-by-case
        for rule in "${existing_rules[@]}"
        do
                # Found rule is for same arch & key, but differs (e.g. in count of -S arguments)
                if [ "${rule}" != "${full_rule}" ]
                then
                        # If so, isolate just '(-S \w)+' substring of that rule
                        rule_syscalls=$(echo $rule | grep -o -P '(-S \w+ )+')
                        # Check if list of '-S syscall' arguments of that rule is subset
                        # of '-S syscall' list of expected $full_rule
                        if grep -q -- "$rule_syscalls" <<< "$full_rule"
                        then
                                # Rule is covered (i.e. the list of -S syscalls for this rule is
                                # subset of -S syscalls of $full_rule => existing rule can be deleted
                                # Thus delete the rule from audit.rules & our array
                                sed -i -e "/$rule/d" "$audit_file"
                                existing_rules=("${existing_rules[@]//$rule/}")
                        else
                                # Rule isn't covered by $full_rule - it besides -S syscall arguments
                                # for this group contains also -S syscall arguments for other syscall
                                # group. Example: '-S lchown -S fchmod -S fchownat' => group='chown'
                                # since 'lchown' & 'fchownat' share 'chown' substring
                                # Therefore:
                                # * 1) delete the original rule from audit.rules
                                # (original '-S lchown -S fchmod -S fchownat' rule would be deleted)
                                # * 2) delete the -S syscall arguments for this syscall group, but
                                # keep those not belonging to this syscall group
                                # (original '-S lchown -S fchmod -S fchownat' would become '-S fchmod'
                                # * 3) append the modified (filtered) rule again into audit.rules
                                # if the same rule not already present
                                #
                                # 1) Delete the original rule
                                sed -i -e "/$rule/d" "$audit_file"
                                # 2) Delete syscalls for this group, but keep those from other groups
                                # Convert current rule syscall's string into array splitting by '-S' delimiter
                                IFS=$'-S' read -a rule_syscalls_as_array <<< "$rule_syscalls"
                                # Reset IFS back to default
                                unset $IFS
                                # Declare new empty string to hold '-S syscall' arguments from other groups
                                new_syscalls_for_rule=''
                                # Walk through existing '-S syscall' arguments
                                for syscall_arg in "${rule_syscalls_as_array[@]}"
                                do
                                        # Skip empty $syscall_arg values
                                        if [ "$syscall_arg" == '' ]
                                        then
                                                continue
                                        fi
                                        # If the '-S syscall' doesn't belong to current group add it to the new list
                                        # (together with adding '-S' delimiter back for each of such item found)
                                        if grep -q -v -- "$group" <<< "$syscall_arg"
                                        then
                                                new_syscalls_for_rule="$new_syscalls_for_rule -S $syscall_arg"
                                        fi
                                done
                                # Replace original '-S syscall' list with the new one for this rule
                                updated_rule=${rule//$rule_syscalls/$new_syscalls_for_rule}
                                # Squeeze repeated whitespace characters in rule definition (if any) into one
                                updated_rule=$(echo "$updated_rule" | tr -s '[:space:]')
                                # 3) Append the modified / filtered rule again into audit.rules
                                #    (but only in case it's not present yet to prevent duplicate definitions)
                                if ! grep -q -- "$updated_rule" "$audit_file"
                                then
                                        echo "$updated_rule" >> "$audit_file"
                                fi
                        fi
                else
                        # $audit_file already contains the expected rule form for this
                        # architecture & key => don't insert it second time
                        append_expected_rule=1
                fi
        done

        # We deleted all rules that were subset of the expected one for this arch & key.
        # Also isolated rules containing system calls not from this system calls group.
        # Now append the expected rule if it's not present in $audit_file yet
        if [[ ${append_expected_rule} -eq "0" ]]
        then
                echo "$full_rule" >> "$audit_file"
        fi
done

}

	fix_audit_syscall_rule "auditctl" "$PATTERN" "$GROUP" "$ARCH" "$FULL_RULE"
	fix_audit_syscall_rule "augenrules" "$PATTERN" "$GROUP" "$ARCH" "$FULL_RULE"
done

# Then perform the remediations for the watch rules
# Perform the remediation for both possible tools: 'auditctl' and 'augenrules'

function fix_audit_watch_rule {

# Load function arguments into local variables
local tool="$1"
local path="$2"
local required_access_bits="$3"
local key="$4"

# Check sanity of the input
if [ $# -ne "4" ]
then
        echo "Usage: fix_audit_watch_rule 'tool' 'path' 'bits' 'key'"
        echo "Aborting."
        exit 1
fi

# Create a list of audit *.rules files that should be inspected for presence and correctness
# of a particular audit rule. The scheme is as follows:
#
# -----------------------------------------------------------------------------------------
# Tool used to load audit rules | Rule already defined  |  Audit rules file to inspect    |
# -----------------------------------------------------------------------------------------
#       auditctl                |     Doesn't matter    |  /etc/audit/audit.rules         |
# -----------------------------------------------------------------------------------------
#       augenrules              |          Yes          |  /etc/audit/rules.d/*.rules     |
#       augenrules              |          No           |  /etc/audit/rules.d/$key.rules  |
# -----------------------------------------------------------------------------------------
declare -a files_to_inspect

# Check sanity of the specified audit tool
if [ "$tool" != 'auditctl' ] && [ "$tool" != 'augenrules' ]
then
        echo "Unknown audit rules loading tool: $1. Aborting."
        echo "Use either 'auditctl' or 'augenrules'!"
        exit 1
# If the audit tool is 'auditctl', then add '/etc/audit/audit.rules'
# into the list of files to be inspected
elif [ "$tool" == 'auditctl' ]
then
        files_to_inspect=("${files_to_inspect[@]}" '/etc/audit/audit.rules')
# If the audit is 'augenrules', then check if rule is already defined
# If rule is defined, add '/etc/audit/rules.d/*.rules' to list of files for inspection.
# If rule isn't defined, add '/etc/audit/rules.d/$key.rules' to list of files for inspection.
elif [ "$tool" == 'augenrules' ]
then
        # Case when particular audit rule is already defined in some of /etc/audit/rules.d/*.rules file
        # Get pair -- filepath : matching_row into @matches array
        IFS=$'\n' matches=($(grep -P "[\s]*-w[\s]+$path" /etc/audit/rules.d/*.rules))
        # Reset IFS back to default
        unset $IFS
        # For each of the matched entries
        for match in "${matches[@]}"
        do
                # Extract filepath from the match
                rulesd_audit_file=$(echo $match | cut -f1 -d ':')
                # Append that path into list of files for inspection
                files_to_inspect=("${files_to_inspect[@]}" "$rulesd_audit_file")
        done
        # Case when particular audit rule isn't defined yet
        if [ ${#files_to_inspect[@]} -eq "0" ]
        then
                # Append '/etc/audit/rules.d/$key.rules' into list of files for inspection
                files_to_inspect="/etc/audit/rules.d/$key.rules"
                # If the $key.rules file doesn't exist yet, create it with correct permissions
                if [ ! -e "$files_to_inspect" ]
                then
                        touch "$files_to_inspect"
                        chmod 0640 "$files_to_inspect"
                fi
        fi
fi

# Finally perform the inspection and possible subsequent audit rule
# correction for each of the files previously identified for inspection
for audit_rules_file in "${files_to_inspect[@]}"
do

        # Check if audit watch file system object rule for given path already present
        if grep -q -P -- "[\s]*-w[\s]+$path" "$audit_rules_file"
        then
                # Rule is found => verify yet if existing rule definition contains
                # all of the required access type bits

                # Escape slashes in path for use in sed pattern below
                local esc_path=${path//$'/'/$'\/'}
                # Define BRE whitespace class shortcut
                local sp="[[:space:]]"
                # Extract current permission access types (e.g. -p [r|w|x|a] values) from audit rule
                current_access_bits=$(sed -ne "s/$sp*-w$sp\+$esc_path$sp\+-p$sp\+\([rxwa]\{1,4\}\).*/\1/p" "$audit_rules_file")
                # Split required access bits string into characters array
                # (to check bit's presence for one bit at a time)
                for access_bit in $(echo "$required_access_bits" | grep -o .)
                do
                        # For each from the required access bits (e.g. 'w', 'a') check
                        # if they are already present in current access bits for rule.
                        # If not, append that bit at the end
                        if ! grep -q "$access_bit" <<< "$current_access_bits"
                        then
                                # Concatenate the existing mask with the missing bit
                                current_access_bits="$current_access_bits$access_bit"
                        fi
                done
                # Propagate the updated rule's access bits (original + the required
                # ones) back into the /etc/audit/audit.rules file for that rule
                sed -i "s/\($sp*-w$sp\+$esc_path$sp\+-p$sp\+\)\([rxwa]\{1,4\}\)\(.*\)/\1$current_access_bits\3/" "$audit_rules_file"
        else
                # Rule isn't present yet. Append it at the end of $audit_rules_file file
                # with proper key

                echo "-w $path -p $required_access_bits -k $key" >> "$audit_rules_file"
        fi
done
}

fix_audit_watch_rule "auditctl" "/etc/issue" "wa" "audit_rules_networkconfig_modification"
fix_audit_watch_rule "augenrules" "/etc/issue" "wa" "audit_rules_networkconfig_modification"

function fix_audit_watch_rule {

# Load function arguments into local variables
local tool="$1"
local path="$2"
local required_access_bits="$3"
local key="$4"

# Check sanity of the input
if [ $# -ne "4" ]
then
        echo "Usage: fix_audit_watch_rule 'tool' 'path' 'bits' 'key'"
        echo "Aborting."
        exit 1
fi

# Create a list of audit *.rules files that should be inspected for presence and correctness
# of a particular audit rule. The scheme is as follows:
#
# -----------------------------------------------------------------------------------------
# Tool used to load audit rules | Rule already defined  |  Audit rules file to inspect    |
# -----------------------------------------------------------------------------------------
#       auditctl                |     Doesn't matter    |  /etc/audit/audit.rules         |
# -----------------------------------------------------------------------------------------
#       augenrules              |          Yes          |  /etc/audit/rules.d/*.rules     |
#       augenrules              |          No           |  /etc/audit/rules.d/$key.rules  |
# -----------------------------------------------------------------------------------------
declare -a files_to_inspect

# Check sanity of the specified audit tool
if [ "$tool" != 'auditctl' ] && [ "$tool" != 'augenrules' ]
then
        echo "Unknown audit rules loading tool: $1. Aborting."
        echo "Use either 'auditctl' or 'augenrules'!"
        exit 1
# If the audit tool is 'auditctl', then add '/etc/audit/audit.rules'
# into the list of files to be inspected
elif [ "$tool" == 'auditctl' ]
then
        files_to_inspect=("${files_to_inspect[@]}" '/etc/audit/audit.rules')
# If the audit is 'augenrules', then check if rule is already defined
# If rule is defined, add '/etc/audit/rules.d/*.rules' to list of files for inspection.
# If rule isn't defined, add '/etc/audit/rules.d/$key.rules' to list of files for inspection.
elif [ "$tool" == 'augenrules' ]
then
        # Case when particular audit rule is already defined in some of /etc/audit/rules.d/*.rules file
        # Get pair -- filepath : matching_row into @matches array
        IFS=$'\n' matches=($(grep -P "[\s]*-w[\s]+$path" /etc/audit/rules.d/*.rules))
        # Reset IFS back to default
        unset $IFS
        # For each of the matched entries
        for match in "${matches[@]}"
        do
                # Extract filepath from the match
                rulesd_audit_file=$(echo $match | cut -f1 -d ':')
                # Append that path into list of files for inspection
                files_to_inspect=("${files_to_inspect[@]}" "$rulesd_audit_file")
        done
        # Case when particular audit rule isn't defined yet
        if [ ${#files_to_inspect[@]} -eq "0" ]
        then
                # Append '/etc/audit/rules.d/$key.rules' into list of files for inspection
                files_to_inspect="/etc/audit/rules.d/$key.rules"
                # If the $key.rules file doesn't exist yet, create it with correct permissions
                if [ ! -e "$files_to_inspect" ]
                then
                        touch "$files_to_inspect"
                        chmod 0640 "$files_to_inspect"
                fi
        fi
fi

# Finally perform the inspection and possible subsequent audit rule
# correction for each of the files previously identified for inspection
for audit_rules_file in "${files_to_inspect[@]}"
do

        # Check if audit watch file system object rule for given path already present
        if grep -q -P -- "[\s]*-w[\s]+$path" "$audit_rules_file"
        then
                # Rule is found => verify yet if existing rule definition contains
                # all of the required access type bits

                # Escape slashes in path for use in sed pattern below
                local esc_path=${path//$'/'/$'\/'}
                # Define BRE whitespace class shortcut
                local sp="[[:space:]]"
                # Extract current permission access types (e.g. -p [r|w|x|a] values) from audit rule
                current_access_bits=$(sed -ne "s/$sp*-w$sp\+$esc_path$sp\+-p$sp\+\([rxwa]\{1,4\}\).*/\1/p" "$audit_rules_file")
                # Split required access bits string into characters array
                # (to check bit's presence for one bit at a time)
                for access_bit in $(echo "$required_access_bits" | grep -o .)
                do
                        # For each from the required access bits (e.g. 'w', 'a') check
                        # if they are already present in current access bits for rule.
                        # If not, append that bit at the end
                        if ! grep -q "$access_bit" <<< "$current_access_bits"
                        then
                                # Concatenate the existing mask with the missing bit
                                current_access_bits="$current_access_bits$access_bit"
                        fi
                done
                # Propagate the updated rule's access bits (original + the required
                # ones) back into the /etc/audit/audit.rules file for that rule
                sed -i "s/\($sp*-w$sp\+$esc_path$sp\+-p$sp\+\)\([rxwa]\{1,4\}\)\(.*\)/\1$current_access_bits\3/" "$audit_rules_file"
        else
                # Rule isn't present yet. Append it at the end of $audit_rules_file file
                # with proper key

                echo "-w $path -p $required_access_bits -k $key" >> "$audit_rules_file"
        fi
done
}

fix_audit_watch_rule "auditctl" "/etc/issue.net" "wa" "audit_rules_networkconfig_modification"
fix_audit_watch_rule "augenrules" "/etc/issue.net" "wa" "audit_rules_networkconfig_modification"

function fix_audit_watch_rule {

# Load function arguments into local variables
local tool="$1"
local path="$2"
local required_access_bits="$3"
local key="$4"

# Check sanity of the input
if [ $# -ne "4" ]
then
        echo "Usage: fix_audit_watch_rule 'tool' 'path' 'bits' 'key'"
        echo "Aborting."
        exit 1
fi

# Create a list of audit *.rules files that should be inspected for presence and correctness
# of a particular audit rule. The scheme is as follows:
#
# -----------------------------------------------------------------------------------------
# Tool used to load audit rules | Rule already defined  |  Audit rules file to inspect    |
# -----------------------------------------------------------------------------------------
#       auditctl                |     Doesn't matter    |  /etc/audit/audit.rules         |
# -----------------------------------------------------------------------------------------
#       augenrules              |          Yes          |  /etc/audit/rules.d/*.rules     |
#       augenrules              |          No           |  /etc/audit/rules.d/$key.rules  |
# -----------------------------------------------------------------------------------------
declare -a files_to_inspect

# Check sanity of the specified audit tool
if [ "$tool" != 'auditctl' ] && [ "$tool" != 'augenrules' ]
then
        echo "Unknown audit rules loading tool: $1. Aborting."
        echo "Use either 'auditctl' or 'augenrules'!"
        exit 1
# If the audit tool is 'auditctl', then add '/etc/audit/audit.rules'
# into the list of files to be inspected
elif [ "$tool" == 'auditctl' ]
then
        files_to_inspect=("${files_to_inspect[@]}" '/etc/audit/audit.rules')
# If the audit is 'augenrules', then check if rule is already defined
# If rule is defined, add '/etc/audit/rules.d/*.rules' to list of files for inspection.
# If rule isn't defined, add '/etc/audit/rules.d/$key.rules' to list of files for inspection.
elif [ "$tool" == 'augenrules' ]
then
        # Case when particular audit rule is already defined in some of /etc/audit/rules.d/*.rules file
        # Get pair -- filepath : matching_row into @matches array
        IFS=$'\n' matches=($(grep -P "[\s]*-w[\s]+$path" /etc/audit/rules.d/*.rules))
        # Reset IFS back to default
        unset $IFS
        # For each of the matched entries
        for match in "${matches[@]}"
        do
                # Extract filepath from the match
                rulesd_audit_file=$(echo $match | cut -f1 -d ':')
                # Append that path into list of files for inspection
                files_to_inspect=("${files_to_inspect[@]}" "$rulesd_audit_file")
        done
        # Case when particular audit rule isn't defined yet
        if [ ${#files_to_inspect[@]} -eq "0" ]
        then
                # Append '/etc/audit/rules.d/$key.rules' into list of files for inspection
                files_to_inspect="/etc/audit/rules.d/$key.rules"
                # If the $key.rules file doesn't exist yet, create it with correct permissions
                if [ ! -e "$files_to_inspect" ]
                then
                        touch "$files_to_inspect"
                        chmod 0640 "$files_to_inspect"
                fi
        fi
fi

# Finally perform the inspection and possible subsequent audit rule
# correction for each of the files previously identified for inspection
for audit_rules_file in "${files_to_inspect[@]}"
do

        # Check if audit watch file system object rule for given path already present
        if grep -q -P -- "[\s]*-w[\s]+$path" "$audit_rules_file"
        then
                # Rule is found => verify yet if existing rule definition contains
                # all of the required access type bits

                # Escape slashes in path for use in sed pattern below
                local esc_path=${path//$'/'/$'\/'}
                # Define BRE whitespace class shortcut
                local sp="[[:space:]]"
                # Extract current permission access types (e.g. -p [r|w|x|a] values) from audit rule
                current_access_bits=$(sed -ne "s/$sp*-w$sp\+$esc_path$sp\+-p$sp\+\([rxwa]\{1,4\}\).*/\1/p" "$audit_rules_file")
                # Split required access bits string into characters array
                # (to check bit's presence for one bit at a time)
                for access_bit in $(echo "$required_access_bits" | grep -o .)
                do
                        # For each from the required access bits (e.g. 'w', 'a') check
                        # if they are already present in current access bits for rule.
                        # If not, append that bit at the end
                        if ! grep -q "$access_bit" <<< "$current_access_bits"
                        then
                                # Concatenate the existing mask with the missing bit
                                current_access_bits="$current_access_bits$access_bit"
                        fi
                done
                # Propagate the updated rule's access bits (original + the required
                # ones) back into the /etc/audit/audit.rules file for that rule
                sed -i "s/\($sp*-w$sp\+$esc_path$sp\+-p$sp\+\)\([rxwa]\{1,4\}\)\(.*\)/\1$current_access_bits\3/" "$audit_rules_file"
        else
                # Rule isn't present yet. Append it at the end of $audit_rules_file file
                # with proper key

                echo "-w $path -p $required_access_bits -k $key" >> "$audit_rules_file"
        fi
done
}

fix_audit_watch_rule "auditctl" "/etc/hosts" "wa" "audit_rules_networkconfig_modification"
fix_audit_watch_rule "augenrules" "/etc/hosts" "wa" "audit_rules_networkconfig_modification"

function fix_audit_watch_rule {

# Load function arguments into local variables
local tool="$1"
local path="$2"
local required_access_bits="$3"
local key="$4"

# Check sanity of the input
if [ $# -ne "4" ]
then
        echo "Usage: fix_audit_watch_rule 'tool' 'path' 'bits' 'key'"
        echo "Aborting."
        exit 1
fi

# Create a list of audit *.rules files that should be inspected for presence and correctness
# of a particular audit rule. The scheme is as follows:
#
# -----------------------------------------------------------------------------------------
# Tool used to load audit rules | Rule already defined  |  Audit rules file to inspect    |
# -----------------------------------------------------------------------------------------
#       auditctl                |     Doesn't matter    |  /etc/audit/audit.rules         |
# -----------------------------------------------------------------------------------------
#       augenrules              |          Yes          |  /etc/audit/rules.d/*.rules     |
#       augenrules              |          No           |  /etc/audit/rules.d/$key.rules  |
# -----------------------------------------------------------------------------------------
declare -a files_to_inspect

# Check sanity of the specified audit tool
if [ "$tool" != 'auditctl' ] && [ "$tool" != 'augenrules' ]
then
        echo "Unknown audit rules loading tool: $1. Aborting."
        echo "Use either 'auditctl' or 'augenrules'!"
        exit 1
# If the audit tool is 'auditctl', then add '/etc/audit/audit.rules'
# into the list of files to be inspected
elif [ "$tool" == 'auditctl' ]
then
        files_to_inspect=("${files_to_inspect[@]}" '/etc/audit/audit.rules')
# If the audit is 'augenrules', then check if rule is already defined
# If rule is defined, add '/etc/audit/rules.d/*.rules' to list of files for inspection.
# If rule isn't defined, add '/etc/audit/rules.d/$key.rules' to list of files for inspection.
elif [ "$tool" == 'augenrules' ]
then
        # Case when particular audit rule is already defined in some of /etc/audit/rules.d/*.rules file
        # Get pair -- filepath : matching_row into @matches array
        IFS=$'\n' matches=($(grep -P "[\s]*-w[\s]+$path" /etc/audit/rules.d/*.rules))
        # Reset IFS back to default
        unset $IFS
        # For each of the matched entries
        for match in "${matches[@]}"
        do
                # Extract filepath from the match
                rulesd_audit_file=$(echo $match | cut -f1 -d ':')
                # Append that path into list of files for inspection
                files_to_inspect=("${files_to_inspect[@]}" "$rulesd_audit_file")
        done
        # Case when particular audit rule isn't defined yet
        if [ ${#files_to_inspect[@]} -eq "0" ]
        then
                # Append '/etc/audit/rules.d/$key.rules' into list of files for inspection
                files_to_inspect="/etc/audit/rules.d/$key.rules"
                # If the $key.rules file doesn't exist yet, create it with correct permissions
                if [ ! -e "$files_to_inspect" ]
                then
                        touch "$files_to_inspect"
                        chmod 0640 "$files_to_inspect"
                fi
        fi
fi

# Finally perform the inspection and possible subsequent audit rule
# correction for each of the files previously identified for inspection
for audit_rules_file in "${files_to_inspect[@]}"
do

        # Check if audit watch file system object rule for given path already present
        if grep -q -P -- "[\s]*-w[\s]+$path" "$audit_rules_file"
        then
                # Rule is found => verify yet if existing rule definition contains
                # all of the required access type bits

                # Escape slashes in path for use in sed pattern below
                local esc_path=${path//$'/'/$'\/'}
                # Define BRE whitespace class shortcut
                local sp="[[:space:]]"
                # Extract current permission access types (e.g. -p [r|w|x|a] values) from audit rule
                current_access_bits=$(sed -ne "s/$sp*-w$sp\+$esc_path$sp\+-p$sp\+\([rxwa]\{1,4\}\).*/\1/p" "$audit_rules_file")
                # Split required access bits string into characters array
                # (to check bit's presence for one bit at a time)
                for access_bit in $(echo "$required_access_bits" | grep -o .)
                do
                        # For each from the required access bits (e.g. 'w', 'a') check
                        # if they are already present in current access bits for rule.
                        # If not, append that bit at the end
                        if ! grep -q "$access_bit" <<< "$current_access_bits"
                        then
                                # Concatenate the existing mask with the missing bit
                                current_access_bits="$current_access_bits$access_bit"
                        fi
                done
                # Propagate the updated rule's access bits (original + the required
                # ones) back into the /etc/audit/audit.rules file for that rule
                sed -i "s/\($sp*-w$sp\+$esc_path$sp\+-p$sp\+\)\([rxwa]\{1,4\}\)\(.*\)/\1$current_access_bits\3/" "$audit_rules_file"
        else
                # Rule isn't present yet. Append it at the end of $audit_rules_file file
                # with proper key

                echo "-w $path -p $required_access_bits -k $key" >> "$audit_rules_file"
        fi
done
}

fix_audit_watch_rule "auditctl" "/etc/sysconfig/network" "wa" "audit_rules_networkconfig_modification"
fix_audit_watch_rule "augenrules" "/etc/sysconfig/network" "wa" "audit_rules_networkconfig_modification"