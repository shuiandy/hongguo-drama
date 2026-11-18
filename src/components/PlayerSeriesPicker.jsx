import { t } from '../i18n';
import React from 'react';
import { Film, X, Trash2, Zap } from './icons';

// Library drawer: switch series, delete local files, clear caches. Player owns confirmation and actions.
export default function PlayerSeriesPicker({
  seriesList, activeSeriesId, query, onQueryChange, onClose, onSelect,
  downloadedMap, storageMap, storageTotal, cacheInfo, compatCache, fmtSize,
  onDeleteSeriesFiles, onRemoveSeries, onDeleteAll, onClearCache, onClearCompatCache,
}) {
  const keyword = query.trim();
  return (
    <div className="series-picker">
      <div className="series-picker-head">
        <input
          type="text"
          className="input-field"
          aria-label={t("在我的剧库搜索")}
          placeholder={t("搜索剧名…")}
          value={query}
          onChange={(e) => onQueryChange(e.target.value)}
        />
        <button className="icon-btn" title={t("关闭")} onClick={onClose}>
          <X size={16} />
        </button>
      </div>

      <div className="series-picker-list">
        {seriesList.length === 0 && <div className="series-picker-empty">{t("还没有剧集")}</div>}
        {seriesList
          .filter((s) => !keyword || (s.series_title || '').includes(keyword))
          .map((s) => {
            const isActive = String(s.series_id) === String(activeSeriesId);
            const dl = downloadedMap[String(s.series_id)];
            const st = storageMap[String(s.series_id)];
            const hasFiles = st && st.files > 0;
            return (
              <div
                key={s.series_id}
                role="button"
                tabIndex={0}
                aria-label={t(`选择剧集 ${s.series_title}`)}
                onKeyDown={(e) => {
                  if (e.target !== e.currentTarget || !['Enter', ' '].includes(e.key)) return;
                  e.preventDefault();
                  onSelect(s.series_id, isActive);
                }}
                className={`series-row ${isActive ? 'active' : ''}`}
                onClick={() => onSelect(s.series_id, isActive)}
              >
                <div className="series-row-cover">
                  {s.cover ? <img src={s.cover} alt="" loading="lazy" /> : <Film size={14} />}
                </div>
                <div className="series-row-body">
                  <div className="series-row-title">{s.series_title}</div>
                  <div className="series-row-sub">
                    {t(dl && dl.completed > 0 ? `已下载 ${dl.completed}/${dl.total} 集` : `共 ${(s.episodes || []).length} 集 · 未下载`)}
                  </div>
                </div>
                {isActive && <span className="series-row-cur">{t("当前")}</span>}
                {hasFiles && (
                  <button
                    className="icon-btn icon-btn-danger series-row-del"
                    title={t(`删除本地文件（${st.files} 个 · ${fmtSize(st.bytes)}）`)}
                    onClick={(e) => { e.stopPropagation(); onDeleteSeriesFiles(s, st); }}
                  >
                    <Trash2 size={15} />
                  </button>
                )}
                <button
                  className="icon-btn series-row-del"
                  title={t("永久移除剧库记录（不删除本地文件）")}
                  aria-label={t(`永久移除 ${s.series_title} 的剧库记录`)}
                  onClick={(e) => { e.stopPropagation(); onRemoveSeries(s); }}
                >
                  <X size={15} />
                </button>
              </div>
            );
          })}
      </div>

      <div className="series-picker-foot">
        {storageTotal.files > 0 && (
          <span className="series-picker-usage">{t("本地已占用 ")}<b>{t(fmtSize(storageTotal.bytes))}</b> / {t(storageTotal.files)}{t(" 个文件")}</span>
        )}
        {storageTotal.files > 0 && (
          <button className="btn btn-outline btn-sm btn-danger-text" title={t("删除所有已下载的本地文件")} onClick={onDeleteAll}>
            {t("删除全部已下载")}</button>
        )}
        <button className="btn btn-outline btn-sm" onClick={onClearCache} title={t("释放在线播放占用的内存")}>
          <Zap size={14} />{t("清空播放缓存")}{t(cacheInfo.count > 0 ? ` (${cacheInfo.count})` : '')}
        </button>
        {compatCache.files > 0 && (
          <button className="btn btn-outline btn-sm" onClick={onClearCompatCache} title={t("删除转码产生的兼容格式文件")}>
            <Trash2 size={14} />{t("清空转码缓存 (")}{t(fmtSize(compatCache.bytes))})
          </button>
        )}
      </div>
    </div>
  );
}
