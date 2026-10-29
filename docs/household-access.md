# Household access

The household entry point is available only on the main home network:

```text
https://home.hyrax.fyi
```

The portal links to all household web applications: Jellyfin, Audiobookshelf,
Paperless, Homebox, InvoiceShelf, Trilium, and BookOrbit. BookOrbit initially has
an empty library; see [bookorbit.md](./bookorbit.md) before adding books.
A visually separate **Administration**
section links to Kopia backups, Pi-hole, and ntfy without presenting them as
everyday household tools. Caddy's health endpoint is omitted because it is a
diagnostic response, not an application interface. Application passwords are never embedded in the
portal.

The grouping is informational rather than an authorization boundary. Every
application remains responsible for authentication and permissions, and all
names remain reachable only through private DNS on the home network.

Jellyfin and Paperless store users and permissions in their application
databases. Those databases are backed up, but their user interfaces are not
stable declarative NixOS interfaces. Perform the following one-time setup after
deploying the portal and record completion without recording the passwords.

## Jellyfin household account

In **Dashboard -> Users**, create a user named `household` with a distinct,
non-empty password. Configure it as follows:

- Do not grant server-administration permission.
- Grant access only to the intended household media libraries.
- Allow media playback and transcoding, but not media deletion.
- Do not allow Live TV or recording management unless those features are
  deliberately introduced later.
- Do not allow remote connections; the current service is LAN-only.
- Leave Quick Connect available for television and streaming-device setup.
- Hide the separate administrator account from login screens.

Sign out of the administrator account, sign in as `household`, play a test
item, and confirm that no dashboard or deletion controls are available.

## Paperless household account

In **Settings -> Users & Groups**, create a group and a user, both named
`household`. Give the user a distinct, non-empty password, make it a member of
the group, and leave both **Superuser** and **Admin status** disabled.

Grant the group these global application permissions:

| Object | Permissions |
| --- | --- |
| Document | View, Add, Change |
| Correspondent | View, Add, Change |
| Document Type | View, Add, Change |
| Tag | View, Add, Change |
| Storage Path | View, Add, Change |
| Custom Field | View, Add, Change |
| Note | View, Add, Change |
| Saved View | View, Add, Change |
| Share Link | View, Add, Delete |
| UI Settings | View, Change |

Do not grant document deletion, user or group management, workflow management,
mail configuration, application configuration, task dismissal, or system
monitoring. Share-link deletion is included because it revokes access to a
shared document; it does not delete the document itself.

Global permissions allow use of an application area. Paperless object
permissions independently determine which documents and metadata the account
can see or edit. Create a **Consumption Started** workflow filtered to the
consumption-folder source whose assignment action:

- sets the document owner to the `household` user; and
- grants the `household` group view and change permission.

The owner assignment is necessary for the household account to create share
links. Apply the same owner and group permissions in bulk to existing shared
documents. Apply household group permissions to shared correspondents, tags,
document types, storage paths, and custom fields as needed so their names do
not appear as private.

Sign out of the administrator account and verify that `household` can:

1. Find and open a scanner-ingested document.
2. Upload a disposable document.
3. Correct its title, date, correspondent, document type, and tags.
4. Create and then revoke a share link.
5. Not delete a document or access administrative settings.

## Calendar household account

Radicale uses a separate `household` login shared by all family devices.
Everyone has equal calendar access. Use its distinct SOPS-managed password;
see [calendar.md](calendar.md) for setup, sync expectations, and recovery.

## Share-link policy

Paperless share links are bearer credentials: anyone who can reach Paperless
and knows the complete random URL can open the shared file without signing in.
Select an expiration one week from creation unless a shorter period is clearly
sufficient, and revoke a link when it is no longer needed. Paperless does not
enforce this household convention as a server-wide default.

The links are currently LAN-only because private DNS and the firewall make
Paperless unreachable from the public internet. Reassess this policy before
adding remote access or public ingress.

## Network acceptance checks

From a device on the main network, confirm the portal and linked applications:

```console
curl --fail https://home.hyrax.fyi
curl --fail https://jellyfin.home.hyrax.fyi/health
curl --fail --head https://audiobookshelf.home.hyrax.fyi
curl --fail --head https://paperless.home.hyrax.fyi
curl --fail https://homebox.home.hyrax.fyi/api/v1/status
curl --fail --head https://invoices.home.hyrax.fyi
curl --fail --head https://pihole.home.hyrax.fyi/admin/
```

ntfy requires authentication and should reject an anonymous subscription; its
authenticated acceptance procedure remains in `docs/operational-monitoring.md`.

Eero Guest Wi-Fi is the visitor network and must remain distinct from the main
network. From a laptop connected to Guest Wi-Fi, confirm both private DNS and
direct routing are unavailable:

```console
dig home.hyrax.fyi
curl --connect-timeout 5 https://192.168.4.22
curl --connect-timeout 5 \
  --resolve paperless.home.hyrax.fyi:443:192.168.4.22 \
  https://paperless.home.hyrax.fyi
```

The private name must not return the homeserver address, and both connection
attempts must fail. The final command bypasses DNS and therefore verifies
network segmentation rather than relying only on name-resolution failure.

Repeat the direct-routing test after material router changes. Guest isolation
does not protect against untrusted devices that have been given the main Wi-Fi
credentials.
