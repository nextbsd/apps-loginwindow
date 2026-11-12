/*
 * Copyright (c) 2026, Joseph Maloney
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * PAM authentication for loginwindow.
 *
 * The conversation answers every hidden prompt with the password from
 * the panel and every visible prompt with the user name. Informational
 * and error messages from modules go to the log; the panel shows none of
 * them (a wrong password only shakes it).
 */

#include <stdlib.h>
#include <string.h>
#include <syslog.h>

#include "LWAuth.h"

struct lw_conv_data {
	const char	*user;
	const char	*password;
};

static int
lw_conv(int n, const struct pam_message **msg, struct pam_response **resp,
    void *appdata)
{
	struct lw_conv_data *d = appdata;
	struct pam_response *r;
	int i;

	if (n <= 0 || n > PAM_MAX_NUM_MSG)
		return (PAM_CONV_ERR);
	r = calloc((size_t)n, sizeof(*r));
	if (r == NULL)
		return (PAM_BUF_ERR);
	for (i = 0; i < n; i++) {
		const char *answer = NULL;

		switch (msg[i]->msg_style) {
		case PAM_PROMPT_ECHO_OFF:
			answer = d->password;
			break;
		case PAM_PROMPT_ECHO_ON:
			answer = d->user;
			break;
		case PAM_ERROR_MSG:
		case PAM_TEXT_INFO:
			syslog(LOG_NOTICE, "PAM: %s", msg[i]->msg);
			break;
		default:
			goto fail;
		}
		if (answer != NULL &&
		    (r[i].resp = strdup(answer)) == NULL)
			goto fail;
	}
	*resp = r;
	return (PAM_SUCCESS);
fail:
	for (i = 0; i < n; i++) {
		if (r[i].resp != NULL) {
			explicit_bzero(r[i].resp, strlen(r[i].resp));
			free(r[i].resp);
		}
	}
	free(r);
	*resp = NULL;
	return (PAM_CONV_ERR);
}

pam_handle_t *
LWAuthOpen(const char *user, const char *password, char **canonical)
{
	/* PAM keeps a pointer to the conversation data until pam_end. */
	static struct lw_conv_data data;
	struct pam_conv conv = { lw_conv, &data };
	pam_handle_t *pamh = NULL;
	const void *item;
	int e;

	data.user = user;
	data.password = password;
	*canonical = NULL;

	e = pam_start(LW_PAM_SERVICE, user, &conv, &pamh);
	if (e != PAM_SUCCESS) {
		syslog(LOG_ERR, "pam_start: %s", pam_strerror(pamh, e));
		return (NULL);
	}
	(void)pam_set_item(pamh, PAM_RUSER, "root");

	e = pam_authenticate(pamh, 0);
	if (e != PAM_SUCCESS) {
		syslog(LOG_NOTICE, "login failed for %s: %s", user,
		    pam_strerror(pamh, e));
		goto fail;
	}
	e = pam_acct_mgmt(pamh, 0);
	if (e == PAM_NEW_AUTHTOK_REQD) {
		/* The panel can't change passwords (yet). */
		syslog(LOG_NOTICE, "%s must change the password first; "
		    "log in on a text console to do so", user);
		goto fail;
	}
	if (e != PAM_SUCCESS) {
		syslog(LOG_NOTICE, "account check failed for %s: %s", user,
		    pam_strerror(pamh, e));
		goto fail;
	}
	if (pam_get_item(pamh, PAM_USER, &item) == PAM_SUCCESS &&
	    item != NULL)
		*canonical = strdup(item);
	else
		*canonical = strdup(user);

	e = pam_setcred(pamh, PAM_ESTABLISH_CRED);
	if (e != PAM_SUCCESS) {
		syslog(LOG_ERR, "pam_setcred for %s: %s", user,
		    pam_strerror(pamh, e));
		goto fail;
	}
	e = pam_open_session(pamh, 0);
	if (e != PAM_SUCCESS) {
		syslog(LOG_ERR, "pam_open_session for %s: %s", user,
		    pam_strerror(pamh, e));
		(void)pam_setcred(pamh, PAM_DELETE_CRED);
		goto fail;
	}
	data.password = NULL;
	return (pamh);
fail:
	data.password = NULL;
	free(*canonical);
	*canonical = NULL;
	pam_end(pamh, e);
	return (NULL);
}

void
LWAuthClose(pam_handle_t *pamh)
{
	int e;

	if (pamh == NULL)
		return;
	e = pam_close_session(pamh, 0);
	if (e != PAM_SUCCESS)
		syslog(LOG_WARNING, "pam_close_session: %s",
		    pam_strerror(pamh, e));
	(void)pam_setcred(pamh, PAM_DELETE_CRED);
	pam_end(pamh, e);
}
