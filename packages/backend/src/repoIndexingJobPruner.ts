import { PrismaClient, RepoIndexingJobStatus } from "@sourcebot/db";
import { createLogger, env } from "@sourcebot/shared";
import { setIntervalAsync } from "./utils.js";

const BATCH_SIZE = 10_000;
const ONE_DAY_MS = 24 * 60 * 60 * 1000;

const logger = createLogger('repo-indexing-job-pruner');

/**
 * Prunes terminal (COMPLETED / FAILED) entries from the RepoIndexingJob table.
 *
 * Every repo produces one job per reindex interval, so the table grows without bound
 * (~28k rows/day for 1.1k repos on a 1h reindex interval). The scheduler's anti-join in
 * RepoIndexManager.scheduleIndexJobs scans this table on every polling tick, so an
 * unpruned history makes each tick progressively more expensive.
 *
 * Non-terminal jobs (PENDING / IN_PROGRESS) are never pruned regardless of age — they are
 * live scheduler state, not history.
 */
export class RepoIndexingJobPruner {
    private interval?: NodeJS.Timeout;

    constructor(private db: PrismaClient) {}

    startScheduler() {
        if (env.REPO_INDEXING_JOB_RETENTION_DAYS <= 0) {
            logger.info('REPO_INDEXING_JOB_RETENTION_DAYS is 0, repo indexing job pruning is disabled.');
            return;
        }

        logger.debug(`Repo indexing job pruner started. Retaining jobs for ${env.REPO_INDEXING_JOB_RETENTION_DAYS} days.`);

        // Run immediately on startup, then every 24 hours
        this.pruneOldJobs();
        this.interval = setIntervalAsync(() => this.pruneOldJobs(), ONE_DAY_MS);
    }

    async dispose() {
        if (this.interval) {
            clearInterval(this.interval);
            this.interval = undefined;
        }
    }

    private async pruneOldJobs() {
        const cutoff = new Date(Date.now() - env.REPO_INDEXING_JOB_RETENTION_DAYS * ONE_DAY_MS);
        let totalDeleted = 0;

        logger.debug(`Pruning terminal repo indexing jobs older than ${cutoff.toISOString()}...`);

        // Delete in batches to avoid long-running transactions
        while (true) {
            const batch = await this.db.repoIndexingJob.findMany({
                where: {
                    createdAt: { lt: cutoff },
                    status: { in: [RepoIndexingJobStatus.COMPLETED, RepoIndexingJobStatus.FAILED] },
                },
                select: { id: true },
                take: BATCH_SIZE,
            });

            if (batch.length === 0) break;

            const result = await this.db.repoIndexingJob.deleteMany({
                where: { id: { in: batch.map(r => r.id) } },
            });

            totalDeleted += result.count;

            if (batch.length < BATCH_SIZE) break;
        }

        if (totalDeleted > 0) {
            logger.debug(`Pruned ${totalDeleted} repo indexing job records.`);
        } else {
            logger.debug('No repo indexing job records to prune.');
        }
    }
}
