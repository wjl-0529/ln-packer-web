import {
  Ban,
  AlertCircle,
  Archive,
  BookOpen,
  Check,
  ChevronDown,
  Clock3,
  Download,
  ExternalLink,
  FileText,
  FolderOpen,
  History,
  Loader2,
  Play,
  Search,
  Settings,
  Shield,
  Sparkles,
  Trash2,
} from "lucide-react";
import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import {
  ApiError,
  cancelJob,
  createJob,
  deleteJob,
  downloadUrl as buildDownloadUrl,
  getHealth,
  getJob,
  listJobs,
  openJobEvents,
  previewNovel,
  searchNovels,
} from "./api";
import { useStoredState } from "./hooks";
import type {
  JobFile,
  LogEntry,
  NovelSearchResult,
  PackJob,
  PackJobProgress,
  PreviewResponse,
  RuntimeConfig,
  Volume,
} from "./types";

const exampleUrl = "https://www.bilinovel.com/novel/3765.html";

type View = "pack" | "history" | "downloads" | "sites" | "rules" | "logs";
type DownloadState = {
  status: "idle" | "downloading" | "done" | "error";
  error?: string;
};

type CloudflarePrompt = {
  message: string;
  query: string;
  source: string;
};

const navItems: Array<{
  view: View;
  label: string;
  icon: typeof Archive;
}> = [
  { view: "pack", label: "打包任务", icon: Archive },
  { view: "history", label: "任务记录", icon: History },
  { view: "downloads", label: "下载管理", icon: Download },
  { view: "sites", label: "站点设置", icon: Settings },
  { view: "rules", label: "规则管理", icon: Shield },
  { view: "logs", label: "日志管理", icon: FileText },
];

const viewTitles: Record<View, { title: string; subtitle: string }> = {
  pack: {
    title: "打包任务",
    subtitle: "输入小说链接或中文关键词，选择分卷并生成 EPUB。",
  },
  history: {
    title: "任务记录",
    subtitle: "查看本机保存的任务，服务重启后仍可恢复已完成记录。",
  },
  downloads: {
    title: "下载管理",
    subtitle: "集中查看所有未过期 EPUB，并可回到对应任务。",
  },
  sites: {
    title: "站点设置",
    subtitle: "管理访问令牌、搜索来源和当前服务运行信息。",
  },
  rules: {
    title: "规则管理",
    subtitle: "查看当前打包规则和分卷范围输入方式。",
  },
  logs: {
    title: "日志管理",
    subtitle: "查看当前任务的运行日志和错误摘要。",
  },
};

export function App() {
  const [activeView, setActiveView] = useState<View>("pack");
  const [url, setUrl] = useStoredState("packer:url", "");
  const [token, setToken] = useStoredState("packer:token", "");
  const [history, setHistory] = useStoredState<PackJob[]>("packer:history", []);
  const [preview, setPreview] = useState<PreviewResponse | null>(null);
  const [selectedIndexes, setSelectedIndexes] = useState<Set<number>>(new Set());
  const [rangeText, setRangeText] = useState("");
  const [combineVolume, setCombineVolume] = useState(true);
  const [addChapterTitle, setAddChapterTitle] = useState(true);
  const [activeJob, setActiveJob] = useState<PackJob | null>(null);
  const [jobProgress, setJobProgress] = useState<PackJobProgress | null>(null);
  const [loadingPreview, setLoadingPreview] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [canceling, setCanceling] = useState(false);
  const [deletingJobIds, setDeletingJobIds] = useState<Set<string>>(new Set());
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [cloudflarePrompt, setCloudflarePrompt] =
    useState<CloudflarePrompt | null>(null);
  const [sourceFilter, setSourceFilter] = useStoredState("packer:source", "all");
  const [searching, setSearching] = useState(false);
  const [searchResults, setSearchResults] = useState<NovelSearchResult[]>([]);
  const [expandedVolumes, setExpandedVolumes] = useState<Set<number>>(new Set());
  const [downloadStates, setDownloadStates] = useState<Record<string, DownloadState>>({});
  const [runtimeConfig, setRuntimeConfig] = useState<RuntimeConfig | null>(null);
  const [now, setNow] = useState(() => Date.now());
  const eventSourceRef = useRef<EventSource | null>(null);
  const streamJobIdRef = useRef<string | null>(null);
  const streamRetryAfterRef = useRef(0);
  const pollRef = useRef<number | null>(null);
  const pollJobIdRef = useRef<string | null>(null);
  const zeroTotalRefreshRef = useRef<Record<string, number>>({});

  const selectedVolumes = useMemo(() => {
    if (!preview) return [];
    return preview.catalog.volumes.filter((volume) =>
      selectedIndexes.has(volume.index),
    );
  }, [preview, selectedIndexes]);

  const selectedChapterCount = useMemo(
    () => selectedVolumes.reduce((total, volume) => total + volume.chapterCount, 0),
    [selectedVolumes],
  );

  const downloadableFiles = useMemo(
    () =>
      history.flatMap((job) =>
        job.files.map((file) => ({
          job,
          file,
        })),
      ),
    [history],
  );

  useEffect(() => {
    if (url === exampleUrl) {
      setUrl("");
    }
  }, [url, setUrl]);

  useEffect(() => {
    getHealth()
      .then((data) => setRuntimeConfig(data.config ?? null))
      .catch(() => {});
  }, []);

  useEffect(() => {
    const status = jobProgress?.status ?? activeJob?.status;
    if (status !== "running") return;
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, [activeJob?.status, jobProgress?.status]);

  useEffect(() => {
    let cancelled = false;
    listJobs(token)
      .then((data) => {
        if (cancelled) return;
        const serverJobs = data.jobs.map(normalizeJob).slice(0, 50);
        setHistory(serverJobs);
        const latest = data.jobs[0];
        if (!activeJob && latest) {
          acceptJob(latest, { silentView: true });
        }
      })
      .catch(() => {
        // 访问令牌未设置或服务尚未就绪时，不打断主流程。
      });
    return () => {
      cancelled = true;
    };
  }, [token]);

  useEffect(() => {
    if (!activeJob) return;
    if (needsLiveUpdates(activeJob)) {
      ensureJobStream(activeJob);
    } else {
      stopLiveUpdates(activeJob.id);
    }
  }, [activeJob?.id, activeJob?.status, activeJob?.phase, token]);

  useEffect(() => {
    return () => {
      stopLiveUpdates();
    };
  }, []);

  async function handleLookup() {
    const input = url.trim();
    setCloudflarePrompt(null);
    setNotice(null);
    if (!input) {
      setError("请输入小说链接或中文关键词。");
      return;
    }

    if (isUrl(input)) {
      await loadPreview(input);
      return;
    }

    setError(null);
    setNotice(null);
    setSearching(true);
    setSearchResults([]);
    try {
      const data = await searchNovels(input, sourceFilter, token);
      setSearchResults(data.results);
      if (data.results.length === 0) {
        setError("没有搜索到匹配小说，可以换一个关键词或直接粘贴站点链接。");
      }
    } catch (err) {
      if (
        err instanceof ApiError &&
        err.code === "cloudflare_verification_required"
      ) {
        setCloudflarePrompt({
          message: err.message,
          query: input,
          source: sourceFilter,
        });
        setError(null);
      } else {
        setError(err instanceof Error ? err.message : String(err));
      }
    } finally {
      setSearching(false);
    }
  }

  async function loadPreview(targetUrl: string) {
    setError(null);
    setNotice(null);
    setCloudflarePrompt(null);
    setSearchResults([]);
    setLoadingPreview(true);
    try {
      const data = await previewNovel(targetUrl, token);
      setUrl(targetUrl);
      setPreview(data);
      setSelectedIndexes(new Set(data.catalog.volumes.map((volume) => volume.index)));
      setExpandedVolumes(new Set());
      setRangeText("");
    } catch (err) {
      setPreview(null);
      setSelectedIndexes(new Set());
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoadingPreview(false);
    }
  }

  function handlePickSearchResult(result: NovelSearchResult) {
    setUrl(result.url);
    setSearchResults([]);
    void loadPreview(result.url);
  }

  async function handleStartJob() {
    if (!preview) {
      await handleLookup();
      return;
    }
    if (selectedIndexes.size === 0) {
      setError("请至少选择一个分卷。");
      return;
    }
    setError(null);
    setNotice(null);
    setSubmitting(true);
    try {
      const job = await createJob(
        {
          url,
          volumeIndexes: Array.from(selectedIndexes).sort((a, b) => a - b),
          combineVolume,
          addChapterTitle,
        },
        token,
      );
      acceptJob(job);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setSubmitting(false);
    }
  }

  function acceptJob(job: PackJob, options?: { silentView?: boolean }) {
    const normalizedJob = normalizeJob(job);
    setActiveJob(normalizedJob);
    setJobProgress(progressFromJob(normalizedJob));
    setHistory((items) => upsertJob(items, normalizedJob).slice(0, 50));
    if (
      normalizedJob.novel &&
      normalizedJob.catalog &&
      (!preview || preview.novel.id !== normalizedJob.novel.id)
    ) {
      setPreview({
        novel: normalizedJob.novel,
        catalog: normalizedJob.catalog,
        source: {
          name: sourceLabel(normalizedJob.url),
          url: normalizedJob.url,
        },
      });
      setUrl(normalizedJob.url);
      setSelectedIndexes(new Set(normalizedJob.catalog.volumes.map((volume) => volume.index)));
    }
    if (!options?.silentView) {
      setActiveView("pack");
    }
    if (isTerminalJob(normalizedJob)) {
      stopLiveUpdates(normalizedJob.id);
    } else {
      ensureJobStream(normalizedJob);
    }
  }

  function ensureJobStream(job: PackJob) {
    if (!needsLiveUpdates(job)) {
      stopLiveUpdates(job.id);
      return;
    }
    startPolling(job.id);
    if (streamJobIdRef.current === job.id && eventSourceRef.current) return;
    if (Date.now() < streamRetryAfterRef.current) return;

    closeEventStream();
    eventSourceRef.current = openJobEvents(
      job.id,
      token,
      (nextJob) => acceptJob(nextJob, { silentView: true }),
      handleProgress,
      () => {
        if (streamJobIdRef.current === job.id) {
          streamRetryAfterRef.current = Date.now() + 5000;
          closeEventStream();
          startPolling(job.id);
        }
      },
    );
    streamJobIdRef.current = job.id;
  }

  function handleProgress(progress: PackJobProgress) {
    const normalizedProgress = normalizeProgress(progress);
    setJobProgress(normalizedProgress);
    setActiveJob((job) =>
      job?.id === normalizedProgress.id
        ? applyProgressToJob(job, normalizedProgress)
        : job,
    );
    setHistory((items) =>
      items.map((job) => applyProgressToJob(normalizeJob(job), normalizedProgress)),
    );
    if (isTerminalProgress(normalizedProgress)) {
      stopLiveUpdates(normalizedProgress.id);
      return;
    }
    if (needsCatalogRefresh(normalizedProgress)) {
      const lastRefresh = zeroTotalRefreshRef.current[normalizedProgress.id] ?? 0;
      if (Date.now() - lastRefresh > 2000) {
        zeroTotalRefreshRef.current[normalizedProgress.id] = Date.now();
        void pollJob(normalizedProgress.id);
      }
    }
  }

  function startPolling(jobId: string) {
    if (pollJobIdRef.current === jobId && pollRef.current) return;
    stopPolling();
    pollJobIdRef.current = jobId;
    void pollJob(jobId);
    pollRef.current = window.setInterval(async () => {
      await pollJob(jobId);
    }, 2000);
  }

  async function pollJob(jobId: string) {
    try {
      const job = await getJob(jobId, token);
      acceptJob(job, { silentView: true });
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  function closeEventStream() {
    eventSourceRef.current?.close();
    eventSourceRef.current = null;
    streamJobIdRef.current = null;
  }

  function stopPolling() {
    if (pollRef.current) {
      window.clearInterval(pollRef.current);
      pollRef.current = null;
    }
    pollJobIdRef.current = null;
  }

  function stopLiveUpdates(jobId?: string) {
    if (!jobId || streamJobIdRef.current === jobId) {
      closeEventStream();
    }
    if (!jobId || pollJobIdRef.current === jobId) {
      stopPolling();
    }
  }

  async function handleCancelJob(jobId: string) {
    setCanceling(true);
    setError(null);
    setNotice(null);
    try {
      const job = await cancelJob(jobId, token);
      acceptJob(job, { silentView: true });
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setCanceling(false);
    }
  }

  async function handleDeleteJob(jobId: string) {
    const target = history.find((job) => job.id === jobId);
    const title = target?.novel?.title ?? target?.url ?? "这个任务";
    if (!window.confirm(`删除「${title}」？对应 EPUB 文件和任务目录也会一起删除。`)) {
      return;
    }
    setDeletingJobIds((items) => new Set(items).add(jobId));
    setError(null);
    setNotice(null);
    try {
      const result = await deleteJob(jobId, token);
      removeJobFromUi(jobId);
      if (result.missing) {
        setNotice("服务器无此任务，已清理本地记录。");
      }
    } catch (err) {
      if (err instanceof ApiError && err.status === 404) {
        removeJobFromUi(jobId);
        setNotice("服务器无此任务，已清理本地记录。");
      } else {
        setError(err instanceof Error ? err.message : String(err));
      }
    } finally {
      setDeletingJobIds((items) => {
        const next = new Set(items);
        next.delete(jobId);
        return next;
      });
    }
  }

  function removeJobFromUi(jobId: string) {
    setHistory((items) => items.filter((job) => job.id !== jobId));
    setDownloadStates((states) => {
      const next = { ...states };
      for (const key of Object.keys(next)) {
        if (key.startsWith(`${jobId}:`)) {
          delete next[key];
        }
      }
      return next;
    });
    if (activeJob?.id === jobId) {
      stopLiveUpdates(jobId);
      setActiveJob(null);
      setJobProgress(null);
    }
  }

  function toggleAll() {
    if (!preview) return;
    if (selectedIndexes.size === preview.catalog.volumes.length) {
      setSelectedIndexes(new Set());
      return;
    }
    setSelectedIndexes(new Set(preview.catalog.volumes.map((volume) => volume.index)));
  }

  function toggleVolume(index: number) {
    setSelectedIndexes((current) => {
      const next = new Set(current);
      if (next.has(index)) {
        next.delete(index);
      } else {
        next.add(index);
      }
      return next;
    });
  }

  function toggleVolumeExpanded(index: number) {
    setExpandedVolumes((current) => {
      const next = new Set(current);
      if (next.has(index)) {
        next.delete(index);
      } else {
        next.add(index);
      }
      return next;
    });
  }

  function applyRangeSelection() {
    if (!preview) return;
    try {
      const indexes = parseRange(rangeText, preview.catalog.volumes.length);
      setSelectedIndexes(new Set(indexes));
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  async function handleDownload(jobId: string, file: JobFile) {
    if (file.expired) return;
    setError(null);
    setNotice(null);
    const key = downloadKey(jobId, file.id);
    setDownloadStates((states) => ({
      ...states,
      [key]: { status: "downloading" },
    }));
    try {
      const href = buildDownloadUrl(
        file.downloadUrl ?? `/api/jobs/${jobId}/files/${file.id}`,
        token,
      );
      const response = await fetch(href, { method: "HEAD" });
      if (!response.ok) {
        const message =
          response.status === 404 || response.status === 410
            ? "文件已不存在，建议删除任务记录。"
            : `下载失败 (${response.status})`;
        throw new ApiError(message, response.status);
      }
      const anchor = document.createElement("a");
      anchor.href = href;
      anchor.download = file.name;
      document.body.appendChild(anchor);
      anchor.click();
      anchor.remove();
      setDownloadStates((states) => ({
        ...states,
        [key]: { status: "done" },
      }));
    } catch (err) {
      setDownloadStates((states) => ({
        ...states,
        [key]: {
          status: "error",
          error: err instanceof Error ? err.message : String(err),
        },
      }));
      if (err instanceof ApiError && (err.status === 404 || err.status === 410)) {
        setNotice("文件已不存在，建议删除任务记录。");
      }
    }
  }

  const currentView = viewTitles[activeView];

  return (
    <div className="appShell">
      <Sidebar activeView={activeView} onViewChange={setActiveView} />
      <main className="workspace">
        <Topbar
          title={currentView.title}
          subtitle={currentView.subtitle}
          token={token}
          onTokenChange={setToken}
          onSettings={() => setActiveView("sites")}
        />
        {activeView === "pack" ? (
          <div className="contentGrid">
            <section className="leftColumn">
              <UrlPanel
                value={url}
                source={sourceFilter}
                loading={loadingPreview || searching}
                searchResults={searchResults}
                onValueChange={setUrl}
                onSourceChange={setSourceFilter}
                onLookup={handleLookup}
                onPickSearchResult={handlePickSearchResult}
              />
              {notice ? <NoticeBanner message={notice} /> : null}
              {error ? <ErrorBanner message={error} /> : null}
              {cloudflarePrompt ? (
                <CloudflarePanel
                  prompt={cloudflarePrompt}
                  onRetry={handleLookup}
                  onUseUrl={(value) => {
                    setUrl(value);
                    void loadPreview(value);
                  }}
                />
              ) : null}
              <NovelPanel preview={preview} loading={loadingPreview} />
              <VolumePanel
                volumes={preview?.catalog.volumes ?? []}
                selectedIndexes={selectedIndexes}
                expandedIndexes={expandedVolumes}
                rangeText={rangeText}
                onRangeTextChange={setRangeText}
                onApplyRange={applyRangeSelection}
                onToggleAll={toggleAll}
                onToggleVolume={toggleVolume}
                onToggleExpanded={toggleVolumeExpanded}
              />
            </section>
            <section className="rightColumn">
              <ProgressPanel
                job={activeJob}
                progress={jobProgress}
                now={now}
                canceling={canceling}
                onCancel={handleCancelJob}
              />
              <ResultPanel
                job={activeJob}
                downloadStates={downloadStates}
                onDownload={handleDownload}
              />
              <HistoryPanel
                jobs={history}
                onOpen={acceptJob}
                onDelete={handleDeleteJob}
                deletingIds={deletingJobIds}
                compact
              />
            </section>
          </div>
        ) : null}

        {activeView === "history" ? (
          <ManagementView>
            <HistoryPanel
              jobs={history}
              onOpen={acceptJob}
              onDelete={handleDeleteJob}
              deletingIds={deletingJobIds}
            />
          </ManagementView>
        ) : null}

        {activeView === "downloads" ? (
          <ManagementView>
            <DownloadManager
              files={downloadableFiles}
              states={downloadStates}
              onDownload={handleDownload}
              onOpenJob={acceptJob}
            />
          </ManagementView>
        ) : null}

        {activeView === "sites" ? (
          <ManagementView>
            <SiteSettings
              token={token}
              source={sourceFilter}
              config={runtimeConfig}
              onTokenChange={setToken}
              onSourceChange={setSourceFilter}
            />
          </ManagementView>
        ) : null}

        {activeView === "rules" ? (
          <ManagementView>
            <RulesPanel />
          </ManagementView>
        ) : null}

        {activeView === "logs" ? (
          <ManagementView>
            <LogsPanel
              job={activeJob}
              jobs={history}
              onOpen={acceptJob}
              onDelete={handleDeleteJob}
              deletingIds={deletingJobIds}
            />
          </ManagementView>
        ) : null}

        {activeView === "pack" ? (
          <OptionsBar
            combineVolume={combineVolume}
            addChapterTitle={addChapterTitle}
            selectedVolumeCount={selectedVolumes.length}
            selectedChapterCount={selectedChapterCount}
            submitting={submitting}
            disabled={!preview || selectedIndexes.size === 0}
            onCombineChange={setCombineVolume}
            onAddTitleChange={setAddChapterTitle}
            onStart={handleStartJob}
          />
        ) : null}
      </main>
    </div>
  );
}

function Sidebar({
  activeView,
  onViewChange,
}: {
  activeView: View;
  onViewChange: (view: View) => void;
}) {
  return (
    <aside className="sidebar">
      <div className="brand">
        <BookOpen size={28} />
        <span>bili-novel-UI-Packer</span>
      </div>
      <nav className="navList">
        {navItems.map((item) => (
          <button
            className={item.view === activeView ? "navItem active" : "navItem"}
            key={item.view}
            onClick={() => onViewChange(item.view)}
            type="button"
          >
            <item.icon size={18} />
            {item.label}
          </button>
        ))}
      </nav>
      <div className="serverCard">
        <span className="liveDot" />
        <div>
          <strong>服务运行中</strong>
          <small>本地 / Docker Web App</small>
        </div>
      </div>
    </aside>
  );
}

function Topbar({
  title,
  subtitle,
  token,
  onTokenChange,
  onSettings,
}: {
  title: string;
  subtitle: string;
  token: string;
  onTokenChange: (value: string) => void;
  onSettings: () => void;
}) {
  return (
    <header className="topbar">
      <div>
        <h1>{title}</h1>
        <p>{subtitle}</p>
      </div>
      <div className="topControls">
        <label className="tokenInput">
          <Shield size={15} />
          <input
            value={token}
            onChange={(event) => onTokenChange(event.target.value)}
            placeholder="访问令牌"
            type="password"
          />
        </label>
        <button className="ghostButton" onClick={onSettings} type="button">
          <Settings size={16} />
          设置
        </button>
      </div>
    </header>
  );
}

function UrlPanel({
  value,
  source,
  loading,
  searchResults,
  onValueChange,
  onSourceChange,
  onLookup,
  onPickSearchResult,
}: {
  value: string;
  source: string;
  loading: boolean;
  searchResults: NovelSearchResult[];
  onValueChange: (value: string) => void;
  onSourceChange: (value: string) => void;
  onLookup: () => void;
  onPickSearchResult: (result: NovelSearchResult) => void;
}) {
  const mode = isUrl(value.trim()) ? "获取信息" : "搜索小说";

  return (
    <section className="panel urlPanel">
      <div className="sectionTitle">
        <span>1. 输入小说链接或搜索关键词</span>
        <small>支持哔哩轻小说、轻小说文库</small>
      </div>
      <div className="urlRow">
        <input
          value={value}
          onChange={(event) => onValueChange(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter") {
              onLookup();
            }
          }}
          placeholder="输入中文书名，或粘贴 https://www.bilinovel.com/novel/3765.html"
        />
        <select
          className="sourceSelect"
          value={source}
          onChange={(event) => onSourceChange(event.target.value)}
        >
          <option value="all">全部站点</option>
          <option value="bili">哔哩轻小说</option>
          <option value="wenku">轻小说文库</option>
        </select>
        <button className="primaryButton" disabled={loading} onClick={onLookup} type="button">
          {loading ? <Loader2 className="spin" size={18} /> : <Search size={18} />}
          {mode}
        </button>
      </div>
      <div className="sourceBadges">
        <span className="sourceBadge red">哔哩轻小说</span>
        <span className="sourceBadge blue">轻小说文库</span>
        <button
          className="sampleLink"
          onClick={() => onValueChange(exampleUrl)}
          type="button"
        >
          填入示例链接
        </button>
      </div>
      {searchResults.length > 0 ? (
        <div className="searchResults">
          {searchResults.map((result) => (
            <button
              className="searchResult"
              key={`${result.source}:${result.id}`}
              onClick={() => onPickSearchResult(result)}
              type="button"
            >
              <div className="searchCover">
                {result.coverUrl ? (
                  <img src={result.coverUrl} alt="" />
                ) : (
                  <BookOpen size={20} />
                )}
              </div>
              <div>
                <strong>{result.title}</strong>
                <small>
                  {result.sourceName}
                  {result.author ? ` · ${result.author}` : ""}
                </small>
                {result.description ? <p>{result.description}</p> : null}
              </div>
              <ExternalLink size={16} />
            </button>
          ))}
        </div>
      ) : null}
    </section>
  );
}

function CloudflarePanel({
  prompt,
  onRetry,
  onUseUrl,
}: {
  prompt: CloudflarePrompt;
  onRetry: () => void;
  onUseUrl: (url: string) => void;
}) {
  const [manualUrl, setManualUrl] = useState("");
  const links = cloudflareLinks(prompt.query, prompt.source);
  return (
    <section className="panel cloudflarePanel">
      <div className="sectionTitle">
        <span>需要先完成源站验证</span>
        <small>Cloudflare</small>
      </div>
      <p>{prompt.message}</p>
      <div className="cloudflareActions">
        {links.map((link) => (
          <a href={link.url} key={link.label} rel="noreferrer" target="_blank">
            <ExternalLink size={16} />
            打开{link.label}验证
          </a>
        ))}
        <button className="ghostButton" onClick={onRetry} type="button">
          我已完成验证，重试搜索
        </button>
      </div>
      <div className="manualUrlRow">
        <input
          value={manualUrl}
          onChange={(event) => setManualUrl(event.target.value)}
          placeholder="也可以把验证后打开的小说详情页链接粘贴到这里"
        />
        <button
          className="primaryButton"
          disabled={!manualUrl.trim()}
          onClick={() => onUseUrl(manualUrl.trim())}
          type="button"
        >
          读取目录
        </button>
      </div>
    </section>
  );
}

function NovelPanel({
  preview,
  loading,
}: {
  preview: PreviewResponse | null;
  loading: boolean;
}) {
  if (loading) {
    return (
      <section className="panel novelPanel skeletonPanel">
        <div className="skeleton coverSkeleton" />
        <div className="skeletonText">
          <span />
          <span />
          <span />
        </div>
      </section>
    );
  }

  if (!preview) {
    return (
      <section className="panel emptyNovel">
        <Sparkles size={24} />
        <div>
          <strong>等待读取小说信息</strong>
          <p>获取成功后会显示封面、作者、标签、简介和可选分卷。</p>
        </div>
      </section>
    );
  }

  const { novel, catalog, source } = preview;
  const volumeCount = catalog.volumes.length;
  const chapterCount = catalog.volumes.reduce(
    (total, volume) => total + volume.chapterCount,
    0,
  );

  return (
    <section className="panel novelPanel">
      <div className="sectionTitle success">
        <span>2. 小说信息</span>
        <small>
          <Check size={14} />
          获取成功
        </small>
      </div>
      <div className="novelBody">
        <div className="coverFrame">
          {novel.coverUrl ? (
            <img src={novel.coverUrl} alt={novel.title} />
          ) : (
            <BookOpen size={36} />
          )}
        </div>
        <div className="novelMeta">
          <h2>{novel.title}</h2>
          {novel.alias ? <p className="alias">{novel.alias}</p> : null}
          <div className="metaGrid">
            <span>作者：{novel.author}</span>
            <span>状态：{novel.status}</span>
            <span>来源：{sourceLabel(source.url)}</span>
            <span>
              目录：{volumeCount} 卷 / {chapterCount} 章
            </span>
          </div>
          <div className="tagRow">
            {(novel.tags ?? []).map((tag) => (
              <span key={tag}>{tag}</span>
            ))}
          </div>
          <p className="description">{novel.description || "暂无简介。"}</p>
        </div>
      </div>
    </section>
  );
}

function VolumePanel({
  volumes,
  selectedIndexes,
  expandedIndexes,
  rangeText,
  onRangeTextChange,
  onApplyRange,
  onToggleAll,
  onToggleVolume,
  onToggleExpanded,
}: {
  volumes: Volume[];
  selectedIndexes: Set<number>;
  expandedIndexes: Set<number>;
  rangeText: string;
  onRangeTextChange: (value: string) => void;
  onApplyRange: () => void;
  onToggleAll: () => void;
  onToggleVolume: (index: number) => void;
  onToggleExpanded: (index: number) => void;
}) {
  return (
    <section className="panel volumePanel">
      <div className="sectionTitle">
        <span>3. 选择要打包的分卷</span>
        <small>
          已选择 {selectedIndexes.size} / {volumes.length} 卷
        </small>
      </div>
      <div className="volumeToolbar">
        <label className="checkLabel">
          <input
            checked={volumes.length > 0 && selectedIndexes.size === volumes.length}
            disabled={volumes.length === 0}
            onChange={onToggleAll}
            type="checkbox"
          />
          全选
        </label>
        <div className="rangeControl">
          <input
            value={rangeText}
            onChange={(event) => onRangeTextChange(event.target.value)}
            placeholder="范围：1-3,5"
          />
          <button
            className="ghostButton"
            disabled={volumes.length === 0}
            onClick={onApplyRange}
            type="button"
          >
            按范围选择
          </button>
        </div>
      </div>
      <div className="volumeTable">
        {volumes.length === 0 ? (
          <div className="emptyRows">读取目录后可选择分卷。</div>
        ) : (
          volumes.map((volume) => {
            const expanded = expandedIndexes.has(volume.index);
            return (
              <div className="volumeRowWrap" key={volume.index}>
                <div className="volumeRow">
                  <label className="volumeName">
                    <input
                      checked={selectedIndexes.has(volume.index)}
                      onChange={() => onToggleVolume(volume.index)}
                      type="checkbox"
                    />
                    <button
                      aria-label={expanded ? "收起章节" : "展开章节"}
                      className={expanded ? "chevronButton expanded" : "chevronButton"}
                      onClick={() => onToggleExpanded(volume.index)}
                      type="button"
                    >
                      <ChevronDown size={16} />
                    </button>
                    <span>{volume.name}</span>
                  </label>
                  <span>{volume.chapterCount} 章</span>
                  <small>
                    {volume.chapters
                      .slice(0, 2)
                      .map((chapter) => chapter.name)
                      .join(" / ")}
                  </small>
                </div>
                {expanded ? (
                  <div className="chapterList">
                    {volume.chapters.map((chapter) => (
                      <div className="chapterRow" key={chapter.index}>
                        <span>{chapter.index + 1}</span>
                        <p>{chapter.name}</p>
                      </div>
                    ))}
                  </div>
                ) : null}
              </div>
            );
          })
        )}
      </div>
    </section>
  );
}

function ProgressPanel({
  job,
  progress,
  now,
  canceling,
  onCancel,
}: {
  job: PackJob | null;
  progress: PackJobProgress | null;
  now: number;
  canceling: boolean;
  onCancel: (jobId: string) => void;
}) {
  const state = progress ?? (job ? progressFromJob(job) : null);
  const steps = ["解析链接", "获取章节", "下载内容", "生成 EPUB", "完成"];
  const currentStep =
    state?.status === "completed"
      ? 4
      : state?.phase === "writing"
        ? 3
        : state?.phase?.includes("chapter") || state?.phase === "images"
          ? 2
          : state
            ? 1
            : 0;
  const canCancel =
    !!job && (state?.status === "queued" || state?.status === "running");
  const elapsed = state?.startedAt
    ? formatDuration(((state.finishedAt ? Date.parse(state.finishedAt) : now) - Date.parse(state.startedAt)) / 1000)
    : "未开始";
  const eta =
    state && state.startedAt && state.percent > 0 && state.status === "running"
      ? estimateRemaining(state, now)
      : "--";
  const waitingForCatalog =
    state?.status === "running" &&
    (state.total ?? 0) === 0 &&
    state.startedAt &&
    Number.isFinite(Date.parse(state.startedAt)) &&
    now - Date.parse(state.startedAt) > 8000;
  const displayMessage = waitingForCatalog
    ? "正在等待服务端返回目录，请稍候。"
    : state?.message ?? "提交任务后将显示实时进度。";
  const logLines =
    state?.latestLog && job?.logs.every((line) => line.time !== state.latestLog?.time)
      ? [...(job?.logs ?? []), state.latestLog]
      : job?.logs ?? [];

  return (
    <section className="panel progressPanel">
      <div className="sectionTitle">
        <span>5. 打包任务进度</span>
        <small className={`statusPill ${state?.status ?? "idle"}`}>
          {state ? statusLabel(state.status) : "等待任务"}
        </small>
      </div>
      <div className="progressMetaGrid">
        <Metric label="已完成" value={`${state?.completed ?? 0} / ${state?.total ?? 0}`} />
        <Metric label="进行中" value={`${state?.activeChapterCount ?? 0} 章`} />
        <Metric label="已耗时" value={elapsed} />
        <Metric label="预计剩余" value={eta} />
      </div>
      <div className="stepper">
        {steps.map((step, index) => (
          <div className={index <= currentStep ? "step done" : "step"} key={step}>
            <span>{index < currentStep ? <Check size={14} /> : index + 1}</span>
            <small>{step}</small>
          </div>
        ))}
      </div>
      <div className="progressTrack">
        <span style={{ width: `${Math.min(state?.percent ?? 0, 100)}%` }} />
      </div>
      <p className="jobMessage">{displayMessage}</p>
      {state?.currentVolume || state?.currentChapter ? (
        <div className="currentWork">
          {state.currentVolume ? <span>{state.currentVolume}</span> : null}
          {state.currentChapter ? <strong>{state.currentChapter}</strong> : null}
        </div>
      ) : null}
      {state?.error ? <p className="jobError">{state.error}</p> : null}
      {canCancel ? (
        <button
          className="dangerButton"
          disabled={canceling}
          onClick={() => onCancel(job.id)}
          type="button"
        >
          {canceling ? <Loader2 className="spin" size={16} /> : <Ban size={16} />}
          取消打包
        </button>
      ) : null}
      <div className="logBox">
        {(logLines.length ? logLines : [emptyLog()]).slice(-10).map((line, index) => (
          <div className="logRow" key={`${line.message}-${index}`}>
            <span>{line.time ? formatTime(line.time) : "--:--"}</span>
            <strong>{line.level}</strong>
            <p>{line.message}</p>
          </div>
        ))}
      </div>
    </section>
  );
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="metric">
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  );
}

function ResultPanel({
  job,
  downloadStates,
  onDownload,
}: {
  job: PackJob | null;
  downloadStates: Record<string, DownloadState>;
  onDownload: (jobId: string, file: JobFile) => void;
}) {
  const files = job?.files ?? [];
  return (
    <section className="panel resultPanel">
      <div className="sectionTitle">
        <span>6. 已完成的 EPUB</span>
        <small>服务器已生成，本按钮保存到当前设备</small>
      </div>
      {files.length === 0 ? (
        <div className="emptyRows compact">完成后可在这里把 EPUB 保存到当前设备。</div>
      ) : (
        files.map((file) => (
          <FileResult
            file={file}
            jobId={job!.id}
            key={file.id}
            state={downloadStates[downloadKey(job!.id, file.id)]}
            onDownload={onDownload}
          />
        ))
      )}
    </section>
  );
}

function FileResult({
  file,
  jobId,
  state,
  onDownload,
}: {
  file: JobFile;
  jobId: string;
  state?: DownloadState;
  onDownload: (jobId: string, file: JobFile) => void;
}) {
  return (
    <div className="fileRow">
      <Check size={18} />
      <div>
        <strong>{file.name}</strong>
        <small>
          已生成在服务器 · {formatBytes(file.sizeBytes)} · 保留至 {formatDateTime(file.expiresAt)}
        </small>
        {state?.status === "error" ? (
          <small className="downloadError">{state.error}</small>
        ) : null}
      </div>
      <DownloadButton file={file} jobId={jobId} state={state} onDownload={onDownload} />
    </div>
  );
}

function DownloadButton({
  file,
  jobId,
  state,
  onDownload,
}: {
  file: JobFile;
  jobId: string;
  state?: DownloadState;
  onDownload: (jobId: string, file: JobFile) => void;
}) {
  if (file.expired) {
    return (
      <button className="ghostButton" disabled type="button">
        已过期
      </button>
    );
  }

  const label =
    state?.status === "downloading"
      ? "准备中"
      : state?.status === "done"
        ? "已开始"
        : state?.status === "error"
          ? "重试下载"
          : "保存到本机";

  return (
    <button
      className="downloadButton"
      disabled={state?.status === "downloading"}
      onClick={() => onDownload(jobId, file)}
      type="button"
    >
      {state?.status === "downloading" ? (
        <Loader2 className="spin" size={16} />
      ) : (
        <Download size={16} />
      )}
      {label}
    </button>
  );
}

function HistoryPanel({
  jobs,
  onOpen,
  onDelete,
  deletingIds,
  compact = false,
}: {
  jobs: PackJob[];
  onOpen: (job: PackJob) => void;
  onDelete: (jobId: string) => void;
  deletingIds: Set<string>;
  compact?: boolean;
}) {
  return (
    <section className={compact ? "panel historyPanel compactPanel" : "panel historyPanel"}>
      <div className="sectionTitle">
        <span>任务记录</span>
        <small>{jobs.length} 条</small>
      </div>
      {jobs.length === 0 ? (
        <div className="emptyRows compact">暂无历史任务。</div>
      ) : (
        jobs.map((job) => (
          <div className="historyRow" key={job.id}>
            <button className="historyMain" onClick={() => onOpen(job)} type="button">
              <span className={`statusDot ${job.status}`} />
              <div>
                <strong>{job.novel?.title ?? job.url}</strong>
                <small>
                  {job.message} · {formatDateTime(job.updatedAt)}
                </small>
              </div>
              <Clock3 size={14} />
            </button>
            <button
              aria-label="删除任务"
              className="iconDangerButton"
              disabled={deletingIds.has(job.id)}
              onClick={() => onDelete(job.id)}
              type="button"
            >
              {deletingIds.has(job.id) ? (
                <Loader2 className="spin" size={15} />
              ) : (
                <Trash2 size={15} />
              )}
            </button>
          </div>
        ))
      )}
    </section>
  );
}

function DownloadManager({
  files,
  states,
  onDownload,
  onOpenJob,
}: {
  files: Array<{ job: PackJob; file: JobFile }>;
  states: Record<string, DownloadState>;
  onDownload: (jobId: string, file: JobFile) => void;
  onOpenJob: (job: PackJob) => void;
}) {
  const available = files.filter(({ file }) => !file.expired);
  return (
    <section className="panel managementPanel">
      <div className="sectionTitle">
        <span>可下载文件</span>
        <small>{available.length} 个未过期</small>
      </div>
      {files.length === 0 ? (
        <div className="emptyRows">暂无可下载 EPUB。完成任务后会自动出现在这里。</div>
      ) : (
        <div className="downloadList">
          {files.map(({ job, file }) => (
            <div className="downloadManagerRow" key={`${job.id}:${file.id}`}>
              <FileResult
                file={file}
                jobId={job.id}
                state={states[downloadKey(job.id, file.id)]}
                onDownload={onDownload}
              />
              <button className="ghostButton" onClick={() => onOpenJob(job)} type="button">
                <FolderOpen size={16} />
                打开任务
              </button>
            </div>
          ))}
        </div>
      )}
    </section>
  );
}

function SiteSettings({
  token,
  source,
  config,
  onTokenChange,
  onSourceChange,
}: {
  token: string;
  source: string;
  config: RuntimeConfig | null;
  onTokenChange: (value: string) => void;
  onSourceChange: (value: string) => void;
}) {
  return (
    <section className="panel managementPanel">
      <div className="sectionTitle">
        <span>站点与访问设置</span>
        <small>本地保存</small>
      </div>
      <div className="settingsGrid">
        <label>
          <span>访问令牌</span>
          <input
            value={token}
            onChange={(event) => onTokenChange(event.target.value)}
            placeholder="服务器设置 PACKER_ACCESS_TOKEN 后填写"
            type="password"
          />
        </label>
        <label>
          <span>默认搜索来源</span>
          <select value={source} onChange={(event) => onSourceChange(event.target.value)}>
            <option value="all">全部站点</option>
            <option value="bili">哔哩轻小说</option>
            <option value="wenku">轻小说文库</option>
          </select>
        </label>
      </div>
      <div className="infoGrid">
        <InfoCard title="本地使用" text="双击 start.bat 后自动打开 localhost:8080，数据保存在程序目录 data。" />
        <InfoCard title="服务器部署" text="docker compose up -d --build 启动，默认挂载 ./data:/app/data。" />
        <InfoCard
          title="当前打包策略"
          text={
            config
              ? `${config.sourceRateMode === "fast" ? "快速" : "稳定"}模式 · 章节并发 ${config.chapterConcurrency} · 图片并发 ${config.imageConcurrency}`
              : "正在读取运行配置"
          }
        />
      </div>
    </section>
  );
}

function RulesPanel() {
  return (
    <section className="panel managementPanel">
      <div className="sectionTitle">
        <span>当前规则</span>
        <small>打包粒度为分卷</small>
      </div>
      <div className="ruleList">
        <RuleItem title="分卷选择" text="支持全选、逐卷勾选，也支持范围输入，例如 1-3,5。" />
        <RuleItem title="章节查看" text="点击分卷行左侧箭头即可展开章节列表，章节暂用于预览。" />
        <RuleItem title="合并分卷" text="开启后生成一个 EPUB；关闭后按选择的分卷分别生成 EPUB。" />
        <RuleItem title="下载有效期" text="文件默认保留 24 小时，可通过 PACKER_FILE_TTL_HOURS 调整。" />
      </div>
    </section>
  );
}

function LogsPanel({
  job,
  jobs,
  onOpen,
  onDelete,
  deletingIds,
}: {
  job: PackJob | null;
  jobs: PackJob[];
  onOpen: (job: PackJob) => void;
  onDelete: (jobId: string) => void;
  deletingIds: Set<string>;
}) {
  return (
    <section className="panel managementPanel">
      <div className="sectionTitle">
        <span>日志摘要</span>
        <small>{job ? job.novel?.title ?? job.url : "未选择任务"}</small>
      </div>
      <div className="managementGrid">
        <div className="logBox tall">
          {(job?.logs.length ? job.logs : [emptyLog()]).map((line, index) => (
            <div className="logRow" key={`${line.message}-${index}`}>
              <span>{line.time ? formatTime(line.time) : "--:--"}</span>
              <strong>{line.level}</strong>
              <p>{line.message}</p>
            </div>
          ))}
        </div>
        <div className="sideList">
          {jobs.slice(0, 8).map((item) => (
            <div className="historyRow" key={item.id}>
              <button className="historyMain" onClick={() => onOpen(item)} type="button">
                <span className={`statusDot ${item.status}`} />
                <div>
                  <strong>{item.novel?.title ?? item.url}</strong>
                  <small>{statusLabel(item.status)}</small>
                </div>
              </button>
              <button
                aria-label="删除任务"
                className="iconDangerButton"
                disabled={deletingIds.has(item.id)}
                onClick={() => onDelete(item.id)}
                type="button"
              >
                {deletingIds.has(item.id) ? (
                  <Loader2 className="spin" size={15} />
                ) : (
                  <Trash2 size={15} />
                )}
              </button>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

function ManagementView({ children }: { children: ReactNode }) {
  return <div className="managementView">{children}</div>;
}

function InfoCard({ title, text }: { title: string; text: string }) {
  return (
    <div className="infoCard">
      <strong>{title}</strong>
      <p>{text}</p>
    </div>
  );
}

function RuleItem({ title, text }: { title: string; text: string }) {
  return (
    <div className="ruleItem">
      <Check size={17} />
      <div>
        <strong>{title}</strong>
        <p>{text}</p>
      </div>
    </div>
  );
}

function OptionsBar({
  combineVolume,
  addChapterTitle,
  selectedVolumeCount,
  selectedChapterCount,
  submitting,
  disabled,
  onCombineChange,
  onAddTitleChange,
  onStart,
}: {
  combineVolume: boolean;
  addChapterTitle: boolean;
  selectedVolumeCount: number;
  selectedChapterCount: number;
  submitting: boolean;
  disabled: boolean;
  onCombineChange: (value: boolean) => void;
  onAddTitleChange: (value: boolean) => void;
  onStart: () => void;
}) {
  return (
    <footer className="optionsBar">
      <div className="optionGroup">
        <Toggle checked={combineVolume} label="合并分卷" onChange={onCombineChange} />
        <Toggle checked={addChapterTitle} label="添加章节标题" onChange={onAddTitleChange} />
      </div>
      <div className="selectionSummary">
        已选 {selectedVolumeCount} 卷 / {selectedChapterCount} 章
      </div>
      <button className="startButton" disabled={disabled || submitting} onClick={onStart} type="button">
        {submitting ? <Loader2 className="spin" size={18} /> : <Play size={18} />}
        开始打包 EPUB
      </button>
    </footer>
  );
}

function Toggle({
  checked,
  label,
  onChange,
}: {
  checked: boolean;
  label: string;
  onChange: (value: boolean) => void;
}) {
  return (
    <label className="toggle">
      <input checked={checked} onChange={(event) => onChange(event.target.checked)} type="checkbox" />
      <span />
      {label}
    </label>
  );
}

function ErrorBanner({ message }: { message: string }) {
  return (
    <div className="errorBanner">
      <AlertCircle size={18} />
      {message}
    </div>
  );
}

function NoticeBanner({ message }: { message: string }) {
  return (
    <div className="noticeBanner">
      <Check size={18} />
      {message}
    </div>
  );
}

function parseRange(text: string, total: number): number[] {
  const normalized = text
    .trim()
    .replace(/[，、；;]/g, ",")
    .replace(/\s+/g, ",");
  if (!normalized || normalized === "0") {
    return Array.from({ length: total }, (_, index) => index);
  }
  const result = new Set<number>();
  for (const part of normalized.split(",")) {
    if (!part) continue;
    const range = part.split("-");
    if (range.length === 1) {
      result.add(oneBased(range[0], total));
      continue;
    }
    if (range.length !== 2) {
      throw new Error(`无效范围：${part}`);
    }
    let start = oneBased(range[0], total);
    let end = oneBased(range[1], total);
    if (start > end) [start, end] = [end, start];
    for (let index = start; index <= end; index += 1) {
      result.add(index);
    }
  }
  return Array.from(result).sort((a, b) => a - b);
}

function oneBased(value: string, total: number): number {
  const parsed = Number.parseInt(value.trim(), 10);
  if (!Number.isFinite(parsed) || parsed < 1 || parsed > total) {
    throw new Error(`分卷序号超出范围：${value}`);
  }
  return parsed - 1;
}

function upsertJob(items: PackJob[], job: PackJob): PackJob[] {
  const normalized = normalizeJob(job);
  return [normalized, ...items.map(normalizeJob).filter((item) => item.id !== job.id)];
}

function mergeJobs(primary: PackJob[], secondary: PackJob[]): PackJob[] {
  const map = new Map<string, PackJob>();
  for (const job of [...secondary, ...primary]) {
    map.set(job.id, normalizeJob(job));
  }
  return Array.from(map.values()).sort(
    (a, b) => new Date(b.updatedAt).getTime() - new Date(a.updatedAt).getTime(),
  );
}

function normalizeJob(job: PackJob): PackJob {
  return {
    ...job,
    logs: (job.logs ?? []).map(normalizeLogEntry),
  };
}

function progressFromJob(job: PackJob): PackJobProgress {
  return {
    id: job.id,
    status: job.status,
    message: job.message,
    error: job.error,
    phase: job.phase,
    currentVolume: job.currentVolume,
    currentChapter: job.currentChapter,
    activeChapterCount: job.activeChapterCount,
    completed: job.completed,
    total: job.total,
    percent: job.percent,
    updatedAt: job.updatedAt,
    startedAt: job.startedAt,
    finishedAt: job.finishedAt,
    latestLog: job.logs[job.logs.length - 1] ?? null,
  };
}

function applyProgressToJob(job: PackJob, progress: PackJobProgress): PackJob {
  if (job.id !== progress.id) return job;
  const latestLog = progress.latestLog
    ? normalizeLogEntry(progress.latestLog)
    : null;
  return normalizeJob({
    ...job,
    status: progress.status,
    message: progress.message,
    error: progress.error ?? null,
    phase: progress.phase,
    currentVolume: progress.currentVolume,
    currentChapter: progress.currentChapter,
    activeChapterCount:
      progress.activeChapterCount ?? job.activeChapterCount ?? 0,
    completed: progress.completed,
    total: progress.total,
    percent: progress.percent,
    updatedAt: progress.updatedAt,
    startedAt: progress.startedAt ?? job.startedAt,
    finishedAt: progress.finishedAt ?? job.finishedAt,
    logs: appendUniqueLog(job.logs ?? [], latestLog),
  });
}

function appendUniqueLog(logs: LogEntry[], log: LogEntry | null): LogEntry[] {
  if (!log) return logs;
  if (logs.some((item) => sameLogEntry(item, log))) return logs;
  return [...logs, log].slice(-80);
}

function sameLogEntry(left: LogEntry, right: LogEntry): boolean {
  return (
    left.time === right.time &&
    left.level === right.level &&
    left.message === right.message
  );
}

function normalizeLogEntry(log: LogEntry | string): LogEntry {
  if (typeof log === "string") {
    return {
      time: "",
      level: "INFO",
      message: log,
    };
  }
  return log;
}

function normalizeProgress(progress: PackJobProgress): PackJobProgress {
  return {
    ...progress,
    latestLog: progress.latestLog
      ? normalizeLogEntry(progress.latestLog)
      : null,
  };
}

function isTerminalJob(job: Pick<PackJob, "status">): boolean {
  return isTerminalStatus(job.status);
}

function isTerminalProgress(progress: PackJobProgress): boolean {
  return isTerminalStatus(progress.status);
}

function isTerminalStatus(status: PackJob["status"]): boolean {
  return status === "completed" || status === "failed" || status === "canceled";
}

function needsLiveUpdates(
  job: Pick<PackJob, "status"> & { phase?: string | null },
): boolean {
  return (
    job.status === "queued" ||
    job.status === "running" ||
    job.phase === "canceling"
  );
}

function needsCatalogRefresh(progress: PackJobProgress): boolean {
  if (progress.status !== "running" || progress.total > 0 || !progress.startedAt) {
    return false;
  }
  const startedAt = Date.parse(progress.startedAt);
  return Number.isFinite(startedAt) && Date.now() - startedAt > 8000;
}

function isUrl(value: string): boolean {
  return /^https?:\/\//i.test(value);
}

function downloadKey(jobId: string, fileId: string): string {
  return `${jobId}:${fileId}`;
}

function sourceLabel(url: string): string {
  if (url.includes("wenku8")) return "轻小说文库";
  return "哔哩轻小说";
}

function statusLabel(status: PackJob["status"]): string {
  const labels = {
    queued: "排队中",
    running: "进行中",
    completed: "已完成",
    failed: "失败",
    canceled: "已取消",
  };
  return labels[status];
}

function emptyLog(): LogEntry {
  return {
    time: "",
    level: "INFO",
    message: "暂无日志。",
  };
}

function estimateRemaining(job: PackJobProgress, now: number): string {
  if (!job.startedAt || job.percent <= 0) return "--";
  const elapsedSeconds = (now - Date.parse(job.startedAt)) / 1000;
  const totalSeconds = elapsedSeconds / (job.percent / 100);
  const remaining = Math.max(0, totalSeconds - elapsedSeconds);
  return formatDuration(remaining);
}

function formatDuration(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return "--";
  const total = Math.round(seconds);
  const minutes = Math.floor(total / 60);
  const rest = total % 60;
  if (minutes <= 0) return `${rest}秒`;
  const hours = Math.floor(minutes / 60);
  const mins = minutes % 60;
  if (hours <= 0) return `${mins}分${rest.toString().padStart(2, "0")}秒`;
  return `${hours}时${mins.toString().padStart(2, "0")}分`;
}

function cloudflareLinks(query: string, source: string) {
  const encoded = encodeURIComponent(query);
  const links = [];
  if (source === "all" || source === "bili") {
    links.push({
      label: "哔哩轻小说",
      url: `https://www.bilinovel.com/search.html?searchkey=${encoded}`,
    });
  }
  if (source === "all" || source === "wenku") {
    links.push({
      label: "轻小说文库",
      url: `https://www.wenku8.net/modules/article/search.php?searchtype=articlename&searchkey=${encoded}&page=1`,
    });
  }
  return links;
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function formatTime(value: string): string {
  return new Intl.DateTimeFormat("zh-CN", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).format(new Date(value));
}

function formatDateTime(value: string): string {
  return new Intl.DateTimeFormat("zh-CN", {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  }).format(new Date(value));
}
