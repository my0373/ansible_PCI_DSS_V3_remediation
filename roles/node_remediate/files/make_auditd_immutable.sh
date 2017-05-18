#!/usr/bin/env bash
# Traverse all of:
#
# /etc/audit/audit.rules,			(for auditctl case)
# /etc/audit/rules.d/*.rules			(for augenrules case)
#
# files to check if '-e .*' setting is present in that '*.rules' file already.
# If found, delete such occurrence since auditctl(8) manual page instructs the
# '-e 2' rule should be placed as the last rule in the configuration
find /etc/audit /etc/audit/rules.d -maxdepth 1 -type f -name *.rules -exec sed -i '/-e[[:space:]]\+.*/d' {} ';'

# Append '-e 2' requirement at the end of both:
# * /etc/audit/audit.rules file 		(for auditctl case)
# * /etc/audit/rules.d/immutable.rules		(for augenrules case)

for AUDIT_FILE in "/etc/audit/audit.rules" "/etc/audit/rules.d/immutable.rules"
do
	echo '' >> $AUDIT_FILE
	echo '# Set the audit.rules configuration immutable per security requirements' >> $AUDIT_FILE
	echo '# Reboot is required to change audit rules once this setting is applied' >> $AUDIT_FILE
	echo '-e 2' >> $AUDIT_FILE
done

# Correct the form of default kernel command line in /etc/default/grub
grep -q ^GRUB_CMDLINE_LINUX=\".*audit=0.*\" /etc/default/grub && \
  sed -i "s/audit=[^[:space:]\+]/audit=1/g" /etc/default/grub
if ! [ $? -eq 0 ]; then
  sed -i "s/\(GRUB_CMDLINE_LINUX=\)\"\(.*\)\"/\1\"\2 audit=1\"/" /etc/default/grub
fi

# Correct the form of kernel command line for each installed kernel
# in the bootloader
/sbin/grubby --update-kernel=ALL --args="audit=1"