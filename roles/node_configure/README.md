node_configure
=========

This role is designed to be applied to a new or existing RHEL system that needs to be made compliant. 

Requirements
------------

At the moment, this has been written for and tested on the following platforms.
* RHEL 7
* CENTOS 7

Role Variables
--------------
MOTD_IMPORTANT:

This is the default message we inject into the MOTD template.

Example:

    MOTD_IMPORTANT: "This is the default message"

ESSENTIAL_PACKAGES:

These are default packages installed by this module.

Example:

    ESSENTIAL_PACKAGES:
      - tree
      - vim
      - git
      - rubygem-foreman_scap_client


Dependencies
------------

No external dependencies.

Example Playbook
----------------

Including an example of how to use your role (for instance, with variables passed in as parameters) is always nice for users too:

    - name: Configure the target node into a known state.
      hosts:  all
      roles:
        - { role: node_configure }

License
-------

MIT

Author Information
------------------

my0373 |at| gmail.com