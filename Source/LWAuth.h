/*
 * Copyright (c) 2026, Joseph Maloney
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * PAM authentication for loginwindow.
 */

#ifndef LW_AUTH_H
#define LW_AUTH_H

#include <security/pam_appl.h>

/* The PAM service: /etc/pam.d/loginwindow, shipped in pam.d/. */
#define LW_PAM_SERVICE	"loginwindow"

/*
 * Authenticates user with password, checks the account, establishes
 * credentials and opens the PAM session. On success it returns the PAM
 * handle (close it with LWAuthClose once the session has ended) and
 * stores the canonical user name (PAM may change it) in *canonical.
 * On failure it returns NULL and logs why.
 */
pam_handle_t	*LWAuthOpen(const char *user, const char *password,
		    char **canonical);

/* Closes the PAM session, deletes credentials and ends PAM. */
void		 LWAuthClose(pam_handle_t *pamh);

#endif
