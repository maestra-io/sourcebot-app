import type { PrismaClient } from '@sourcebot/db';
import { RepoIndexingJobStatus } from '@sourcebot/db';
import { beforeEach, describe, expect, test, vi } from 'vitest';

const mockEnv = { REPO_INDEXING_JOB_RETENTION_DAYS: 7 };

vi.mock('@sourcebot/shared', () => ({
    createLogger: vi.fn(() => ({
        info: vi.fn(),
        warn: vi.fn(),
        error: vi.fn(),
        debug: vi.fn(),
    })),
    get env() {
        return mockEnv;
    },
}));

vi.mock('./utils.js', () => ({
    setIntervalAsync: vi.fn(() => undefined),
}));

const { RepoIndexingJobPruner } = await import('./repoIndexingJobPruner.js');

describe('RepoIndexingJobPruner', () => {
    let mockPrisma: {
        repoIndexingJob: {
            findMany: ReturnType<typeof vi.fn>;
            deleteMany: ReturnType<typeof vi.fn>;
        };
    };

    beforeEach(() => {
        vi.clearAllMocks();
        mockEnv.REPO_INDEXING_JOB_RETENTION_DAYS = 7;
        mockPrisma = {
            repoIndexingJob: {
                findMany: vi.fn().mockResolvedValue([]),
                deleteMany: vi.fn().mockResolvedValue({ count: 0 }),
            },
        };
    });

    const createPruner = () =>
        new RepoIndexingJobPruner(mockPrisma as unknown as PrismaClient);

    test('only prunes terminal jobs older than the retention cutoff', async () => {
        mockPrisma.repoIndexingJob.findMany.mockResolvedValueOnce([{ id: 'job-1' }, { id: 'job-2' }]);
        mockPrisma.repoIndexingJob.deleteMany.mockResolvedValueOnce({ count: 2 });

        createPruner().startScheduler();
        // startScheduler kicks off the first prune without awaiting it.
        await vi.waitFor(() => expect(mockPrisma.repoIndexingJob.deleteMany).toHaveBeenCalled());

        const where = mockPrisma.repoIndexingJob.findMany.mock.calls[0][0].where;
        expect(where.status).toEqual({
            in: [RepoIndexingJobStatus.COMPLETED, RepoIndexingJobStatus.FAILED],
        });
        expect(where.createdAt.lt.getTime()).toBeLessThanOrEqual(Date.now() - 7 * 24 * 60 * 60 * 1000);

        expect(mockPrisma.repoIndexingJob.deleteMany).toHaveBeenCalledWith({
            where: { id: { in: ['job-1', 'job-2'] } },
        });
    });

    test('is a no-op when retention is disabled', async () => {
        mockEnv.REPO_INDEXING_JOB_RETENTION_DAYS = 0;

        createPruner().startScheduler();

        expect(mockPrisma.repoIndexingJob.findMany).not.toHaveBeenCalled();
        expect(mockPrisma.repoIndexingJob.deleteMany).not.toHaveBeenCalled();
    });
});
