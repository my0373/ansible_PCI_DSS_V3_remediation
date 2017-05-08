Ansible Tower + Sat6 demos
=========

A collection of playbooks and roles I use to demonstrate Satellite 6 and Ansible Tower.

The main demo here 
* Preparing the OS for OpenSCAP
* Creating an Ansible user, group and SSH Key
* Copying the tower public key and Ansible to sudoers
* Running an OpenSCAP report
* Securing (to PCI-DSS-v3)
* Running an OpenSCAP report to show compliance
* Configuring the OS
* Updating the kernel only (with reboot)
* Updating security patches only
* Install Apache2 (demo 3rd party repos - creds to geerlingguy.apache)
* Copy static HTML content over
* Enable firewall access over port 80

WARNING: Much of this code needs some love. Bits are hacky (I have pointed this out in comments around the place). However, I did have 2 days to complete it.

It is my intention to try and improve the code as I go, but for now, read it before you run it.
