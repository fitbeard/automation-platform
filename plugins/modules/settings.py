#!/usr/bin/python
# coding: utf-8 -*-

# (c) 2023, Sean Sullivan <@sean-m-sullivan>
# (c) 2018, Nikhil Jain <nikjain@redhat.com>
# (c) 2026, Tadas Sutkaitis <tadasas@gmail.com>
# GNU General Public License v3.0+ (see COPYING or https://www.gnu.org/licenses/gpl-3.0.txt)

from __future__ import absolute_import, division, print_function

__metaclass__ = type


DOCUMENTATION = """
---
module: settings
author: Sean Sullivan (@sean-m-sullivan)
short_description: Modify automation platform gateway settings.
description:
    - Modify automation platform gateway settings.
options:
    settings:
      description:
        - A data structure to be sent into the settings endpoint
      type: dict
      required: True
extends_documentation_fragment: fitbeard.awx.auth
"""

EXAMPLES = """
- name: Configure platform gateway settings
  fitbeard.awx.settings:
    settings:
      gateway_token_name: "<gateway_token_name>"
      gateway_access_token_expiration: 6000
      gateway_basic_auth_enabled: true/false
      gateway_proxy_url: https://localhost:9080
      gateway_proxy_url_ignore_cert: true/false

- name: Configure JWT settings
  fitbeard.awx.settings:
    settings:
      jwt_private_key: "<jwt_private_key>"
      jwt_public_key: |
        -----BEGIN PUBLIC KEY-----
        <public_key_value>
        -----END PUBLIC KEY-----
      jwt_expiration_buffer_in_seconds: <jwt_expiration_buffer_in_seconds>

- name: Set backend and timeout configurations
  fitbeard.awx.settings:
    settings:
      status_endpoint_backend_timeout_seconds: <timeout_seconds>
      status_endpoint_backend_verify: true/false
      resource_client_request_timeout: <timeout_in_seconds>
      request_timeout: <timeout_in_seconds>

- name: Configure password and security policies
  fitbeard.awx.settings:
    settings:
      password_min_length: 0
      password_min_digits: 0
      password_min_upper: 0
      password_min_special: 0
      allow_admins_to_set_insecure: false

- name: Customize login and session behavior
  fitbeard.awx.settings:
    settings:
      LOGIN_REDIRECT_OVERRIDE: "<redirect_url>"
      custom_login_info: "<custom_login_message>"
      custom_logo: "<path_to_logo>"
      SOCIAL_AUTH_USERNAME_IS_FULL_EMAIL: true/false
      SESSION_COOKIE_AGE: <cookie_age_in_seconds>

- name: Configure SSO and OAuth2 settings
  fitbeard.awx.settings:
    settings:
      CONTROLLER_SSO_URL: "<controller_sso_url>"
      AUTOMATION_HUB_SSO_URL: "<automation_hub_sso_url>"
      ALLOW_OAUTH2_FOR_EXTERNAL_USERS: true/false

- name: Set pagination behavior
  fitbeard.awx.settings:
    settings:
      DEFAULT_PAGE_SIZE: <default_page_size>
      MAX_PAGE_SIZE: <max_page_size>

- name: Set Automation Analytics gather interval
  fitbeard.awx.settings:
    settings:
      AUTOMATION_ANALYTICS_GATHER_INTERVAL: <gather_interval_in_seconds>
...
"""

from ..module_utils.aap_module import AAPModule


def main():
    # Any additional arguments that are not fields of the item can be added here
    argument_spec = dict(
        settings=dict(required=True, type="dict"),
    )

    # Create a module for ourselves
    module = AAPModule(argument_spec=argument_spec, supports_check_mode=True)

    new_settings = module.params.get("settings")

    # Load the existing settings
    existing_settings = module.get_endpoint("settings/all")["json"]

    # Begin a json response
    json_output = {"changed": False, "old_values": {}, "new_values": {}}

    # Check any of the settings to see if anything needs to be updated
    needs_update = False
    for a_setting in new_settings:
        if a_setting not in existing_settings or existing_settings[a_setting] != new_settings[a_setting]:
            # At least one thing is different so we need to patch
            needs_update = True
            json_output["old_values"][a_setting] = existing_settings[a_setting]
            json_output["new_values"][a_setting] = new_settings[a_setting]

    if module._diff:
        json_output["diff"] = {"before": json_output["old_values"], "after": json_output["new_values"]}

    # If nothing needs an update we can simply exit with the response (as not changed)
    if not needs_update:
        module.exit_json(**json_output)

    if module.check_mode and module._diff:
        json_output["changed"] = True
        module.exit_json(**json_output)

    # Make the call to update the settings
    url = module.build_url("settings/all")
    response = module.make_request("PUT", url, **{"data": new_settings})

    if response["status_code"] == 200:
        # Set the changed response to True
        json_output["changed"] = True

        # To deal with the old style values we need to return 'value' in the response
        new_values = {}
        for a_setting in new_settings:
            new_values[a_setting] = response["json"][a_setting]

        module.exit_json(**json_output)
    elif "json" in response and "__all__" in response["json"]:
        module.fail_json(msg=response["json"]["__all__"])
    else:
        module.fail_json(**{"msg": "Unable to update settings, see response", "response": response})


if __name__ == "__main__":
    main()
