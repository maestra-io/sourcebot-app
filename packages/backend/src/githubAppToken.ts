// maestra: GitHub App auth for the OSS build (issues-maestra#1455), instead of a PAT.
// With GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID and GITHUB_APP_PRIVATE_KEY set, the backend
// puts an installation token into its own GITHUB_TOKEN and renews it every 30 min (GitHub
// expires it after 60). Connections keep `token: { env: GITHUB_TOKEN }`: getTokenFromConfig
// reads process.env on every call, so the listing and every clone/fetch see the fresh one.
import { createSign } from "crypto";
import { createLogger } from "@sourcebot/shared";

const logger = createLogger('github-app-token');

const RENEW_MS = 30 * 60_000;
const RETRY_MS = 60_000;

export const githubAppJwt = (appId: string, privateKeyPem: string, nowMs = Date.now()): string => {
    const b64 = (value: object) => Buffer.from(JSON.stringify(value)).toString('base64url');
    // GitHub allows 60 s of clock skew and at most 10 min of lifetime.
    const iat = Math.floor(nowMs / 1000) - 60;
    const unsigned = `${b64({ alg: 'RS256', typ: 'JWT' })}.${b64({ iat, exp: iat + 600, iss: appId })}`;
    return `${unsigned}.${createSign('RSA-SHA256').update(unsigned).sign(privateKeyPem, 'base64url')}`;
};

export const mintInstallationToken = async (
    appId: string,
    installationId: string,
    privateKeyPem: string,
    fetchImpl: typeof fetch = fetch,
): Promise<{ token: string, expiresAt: string }> => {
    const response = await fetchImpl(`https://api.github.com/app/installations/${encodeURIComponent(installationId)}/access_tokens`, {
        method: 'POST',
        headers: {
            accept: 'application/vnd.github+json',
            authorization: `Bearer ${githubAppJwt(appId, privateKeyPem)}`,
            'content-type': 'application/json',
            'user-agent': 'sourcebot-maestra',
            'x-github-api-version': '2022-11-28',
        },
        // Down-scoped to what indexing needs, whatever else the App is granted.
        body: JSON.stringify({ permissions: { contents: 'read', metadata: 'read' } }),
    });
    if (!response.ok) {
        throw new Error(`GitHub App installation token request failed: HTTP ${response.status}`);
    }
    const body = await response.json() as { token?: string, expires_at?: string };
    if (!body.token) {
        throw new Error('GitHub App installation token response carried no token');
    }
    return { token: body.token, expiresAt: body.expires_at ?? 'unknown' };
};

/** Returns false when the App is not configured (GITHUB_TOKEN is then used as given). */
export const startGithubAppToken = async (
    env: NodeJS.ProcessEnv = process.env,
    fetchImpl: typeof fetch = fetch,
): Promise<boolean> => {
    const appId = env.GITHUB_APP_ID;
    const installationId = env.GITHUB_APP_INSTALLATION_ID;
    const privateKey = env.GITHUB_APP_PRIVATE_KEY;
    // Out of the environment before anything is spawned: git children inherit it.
    delete env.GITHUB_APP_PRIVATE_KEY;
    if (!appId && !installationId && !privateKey) {
        return false;
    }
    if (!appId || !installationId || !privateKey) {
        throw new Error('GitHub App auth needs all of GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID and GITHUB_APP_PRIVATE_KEY');
    }

    const renew = async () => {
        const { token, expiresAt } = await mintInstallationToken(appId, installationId, privateKey, fetchImpl);
        env.GITHUB_TOKEN = token;
        return expiresAt;
    };
    // A failure here fails the start: a stale PAT or no token at all is worse than a crash loop.
    const expiresAt = await renew();
    logger.info(`GitHub App ${appId} installation ${installationId}: token in use, expires ${expiresAt}`);

    const schedule = (delayMs: number) => {
        setTimeout(() => {
            renew().then(
                (next) => {
                    logger.info(`GitHub App installation token renewed, expires ${next}`);
                    schedule(RENEW_MS);
                },
                (error) => {
                    // The previous token stays until GitHub expires it; never unset it.
                    logger.error(`GitHub App installation token renewal failed, retrying in ${RETRY_MS / 1000}s: ${error}`);
                    schedule(RETRY_MS);
                },
            );
        }, delayMs).unref();
    };
    schedule(RENEW_MS);
    return true;
};
