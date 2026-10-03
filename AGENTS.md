# AppleCam contributor instructions

## Core principles

1. **No fallback solutions.** Never build fallback solutions unless clearly and explicitly instructed to do so. Fallback solutions introduce unnecessary complexity and potential security risks.
2. **Unit testing.** Always create unit tests when possible. Use meaningful coverage that protects behavior. If a feature cannot be easily unit tested, document why and identify the appropriate integration or manual verification.
3. **Sensitive information protection.** Never commit API keys or other sensitive information. Use environment variables, secure vaults or dedicated secret management. Keep strict ignore rules for local secrets and signing material.

## Exceptions

Any exception must be explicitly documented, approved by the team lead and accompanied by a detailed rationale. No exception is assumed by these planning documents.

## Project scope

Use the product requirements and development plan in `docs/`. Preserve the distinction between owner-confirmed requirements, proposed defaults, compile-only checks and runtime acceptance. Do not mark a milestone complete from a successful build alone.

Use public Apple APIs. Preserve System Integrity Protection and other system protections. Do not modify Apple's camera services, replace system drivers, add private API hooks or alter other camera extensions as part of this project.

Automatic raw-camera output, automatic camera substitution, automatic AI background substitution and automatic format reduction are excluded. On an unrecoverable processing or source failure, stop delivering frames and explain the error.

Keep user camera images, private recordings, certificates, private keys, account credentials and signing exports out of commits. A signing team identifier is not a private key, but account details should be recorded only when needed.
