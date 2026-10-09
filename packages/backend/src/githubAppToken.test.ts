import { generateKeyPairSync, createVerify } from 'crypto';
import { describe, expect, test, vi } from 'vitest';
import { githubAppJwt, startGithubAppToken } from './githubAppToken';

vi.mock('@sourcebot/shared', () => ({
    createLogger: () => ({ info: () => {}, error: () => {} }),
}));

const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const pem = privateKey.export({ type: 'pkcs1', format: 'pem' }).toString();

describe('githubAppJwt', () => {
    test('is an RS256 JWT for the app, valid under 10 minutes', () => {
        const jwt = githubAppJwt('123', pem, 1_700_000_000_000);
        const [header, payload, signature] = jwt.split('.');
        expect(JSON.parse(Buffer.from(header, 'base64url').toString())).toEqual({ alg: 'RS256', typ: 'JWT' });
        const claims = JSON.parse(Buffer.from(payload, 'base64url').toString());
        expect(claims).toEqual({ iat: 1_699_999_940, exp: 1_700_000_540, iss: '123' });
        const ok = createVerify('RSA-SHA256').update(`${header}.${payload}`).verify(publicKey, signature, 'base64url');
        expect(ok).toBe(true);
    });
});

describe('startGithubAppToken', () => {
    test('does nothing without the App variables', async () => {
        const env: NodeJS.ProcessEnv = { GITHUB_TOKEN: 'ghp_x' };
        expect(await startGithubAppToken(env, vi.fn())).toBe(false);
        expect(env.GITHUB_TOKEN).toBe('ghp_x');
    });

    test('refuses a partial configuration', async () => {
        await expect(startGithubAppToken({ GITHUB_APP_ID: '1' }, vi.fn())).rejects.toThrow(/needs all of/);
    });

    test('replaces GITHUB_TOKEN and drops the private key from the environment', async () => {
        const fetchImpl = vi.fn(async () => new Response(JSON.stringify({ token: 'ghs_new', expires_at: 'later' }), { status: 201 }));
        const env: NodeJS.ProcessEnv = { GITHUB_APP_ID: '1', GITHUB_APP_INSTALLATION_ID: '2', GITHUB_APP_PRIVATE_KEY: pem, GITHUB_TOKEN: 'ghp_old' };
        expect(await startGithubAppToken(env, fetchImpl as unknown as typeof fetch)).toBe(true);
        expect(env.GITHUB_TOKEN).toBe('ghs_new');
        expect(env.GITHUB_APP_PRIVATE_KEY).toBeUndefined();
        expect(fetchImpl.mock.calls[0][0]).toBe('https://api.github.com/app/installations/2/access_tokens');
    });

    test('fails the start when GitHub refuses the App', async () => {
        const fetchImpl = vi.fn(async () => new Response('{}', { status: 401 }));
        const env: NodeJS.ProcessEnv = { GITHUB_APP_ID: '1', GITHUB_APP_INSTALLATION_ID: '2', GITHUB_APP_PRIVATE_KEY: pem };
        await expect(startGithubAppToken(env, fetchImpl as unknown as typeof fetch)).rejects.toThrow(/HTTP 401/);
    });
});
