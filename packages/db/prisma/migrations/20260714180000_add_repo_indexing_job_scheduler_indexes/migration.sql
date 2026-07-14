-- CreateIndex
CREATE INDEX "RepoIndexingJob_type_status_createdAt_idx" ON "RepoIndexingJob"("type", "status", "createdAt");

-- CreateIndex
CREATE INDEX "RepoIndexingJob_type_status_completedAt_idx" ON "RepoIndexingJob"("type", "status", "completedAt");
