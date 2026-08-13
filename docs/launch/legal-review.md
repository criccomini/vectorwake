# Launch legal review brief

This is the packet for a qualified attorney. It records facts and questions; it is not a legal conclusion. Do not mark the launch review complete until counsel has named the client, jurisdiction, scope, and approval in writing.

## Operator and launch

- Public operator named on the site: Chris.
- Product: a free browser-based multiplayer space combat game.
- Initial hosting: United States, through Vultr cloud compute and managed PostgreSQL.
- Accounts: generated call signs, optional passwords, no email address, no payments, and no player chat.
- Community: a project-run Discord server with no account linkage to the game.
- Source distribution: PolyForm Noncommercial License 1.0.0.

Counsel should confirm the operator's legal name, business form, contact address, governing law, and whether a separate entity should operate the service.

## Privacy questions

The public notice follows the structure of the [ICO small-organisation privacy notice generator](https://ico.org.uk/for-organisations/advice-for-small-organisations/privacy-notices-and-cookies/create-your-own-privacy-notice/) and covers the disclosure categories in [GDPR Article 13](https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX:02016R0679-20160504). It voluntarily offers access, correction, and deletion requests without claiming that every privacy statute applies.

Counsel should review:

1. Whether the operator or service meets any threshold under the California Consumer Privacy Act or another state privacy law.
2. Whether the stated legal bases, United States transfer notice, and processor description are sufficient for players in the UK or EEA.
3. Whether Discord plus a public GitHub fallback is an adequate contact method, or whether launch requires a working privacy email and mailing address.
4. The deletion treatment for rating events, provider backups, bans, and public caches.
5. Whether the general-audience, age-13 floor is appropriate under COPPA and other child privacy rules. The [FTC COPPA guidance](https://www.ftc.gov/business-guidance/resources/complying-coppa-frequently-asked-questions) says a general-audience service may exclude children under 13, but actual knowledge that a user is under 13 changes the operator's duties.
6. Whether the public pilot directory and automatic rating calculation need any additional notice.

## Inherited mechanics and intellectual property

The working position is recorded in `docs/design/identity.md`:

- Vectorwake studies and inherits frictionless inertial flight, energy as health and ammunition, tick timing, configurable arena rules, prizes, bounty, lag behavior, and tuning ratios that began with a Subspace settings file.
- Current Alpha tuning has changed through simulation and play, but its starting point was a translated `arena.conf`.
- The client and repository use new code, ship names, silhouettes, weapon art, sounds, maps, interface, fiction, and product name.
- Original sprites, tiles, sounds, music, overlays, map files, zone names, and game binaries are excluded.
- Alpha now uses a generated map based on measurements rather than converted geometry.
- Internal importers can read legacy maps and settings for research, but imported output does not ship.

Counsel should answer these questions in writing:

1. Does the current use of translated tuning values create copyright, contract, or trade-secret risk?
2. Does the combination and arrangement of mechanics create protectable expression or trade-dress risk even where individual mechanics do not?
3. Are the references to SubSpace on the landing page and Subspace Continuum in the README nominative and presented without a likelihood of affiliation?
4. Should the live zone called Alpha be renamed before launch?
5. Do any research files, commit history, fixtures, or importer tests contain third-party assets or configuration that should not be distributed in a public repository?
6. Is a trademark search and application for Vectorwake advisable before promotion?
7. Does the PolyForm Noncommercial license cover every distributed file, and is a contributor agreement or certificate of origin needed before accepting outside work?

There is one policy contradiction to resolve. `docs/design/identity.md` says other games will not be named in marketing, while the landing-page founder letter names SubSpace. Counsel and product should choose one rule and make both documents agree.

## Terms questions

Counsel should review the age rule, account terms, moderation authority, open-source distinction, independent-project statement, warranty disclaimer, limitation of liability, change process, governing law, and dispute venue. The current terms deliberately omit arbitration, a class-action waiver, and a choice-of-law clause until counsel decides whether any belongs there.

## Sign-off

Record the review here before public launch:

- Attorney and firm:
- Client represented:
- Jurisdictions considered:
- Review date:
- Required changes:
- Approved documents and commit:
- Remaining accepted risks:
