import { t } from '../i18n';
import React from 'react';
import { Check } from './icons';

const episodeTitle = (ep) => t(ep.locked ? '需在来源平台解锁' : ep.status === 'completed'
  ? '点击播放（本地）'
  : ep.status === 'downloading' || ep.status === 'pending'
    ? '下载继续，点击在线播放'
    : '点击在线播放（不下载）· 双击加入下载');

// Episode chips: click plays (local or online), double click queues a download on desktop.
export default function PlayerEpisodeGrid({ episodes, currentIndex, onlineVid, mobile, onSelect, onDownload }) {
  return (
    <div className="player-episodes">
      {episodes.map((ep) => {
        const isCurrent = ep.vid_index === currentIndex;
        return (
          <button
            key={ep.vid_index}
            disabled={ep.locked === true}
            aria-label={t(`第 ${ep.vid_index} 集`)}
            aria-pressed={isCurrent}
            className={`ep-chip ep-${ep.status} ${isCurrent ? 'ep-current' : ''}`}
            onClick={() => onSelect(ep.vid_index)}
            title={episodeTitle(ep)}
            onDoubleClick={() => !mobile && ep.status !== 'completed' && onDownload(ep.vid_index)}
          >
            <span className="ep-num">{t(ep.vid_index)}</span>{ep.locked && <span className="ep-lock-label">{t("锁定")}</span>}
            {ep.status === 'completed' && <Check size={11} className="ep-badge" />}
            {ep.status === 'downloading' && (
              <span className="ep-progress" style={{ width: `${ep.progress || 0}%` }} />
            )}
            {onlineVid === ep.vid && <span className="ep-online-dot" />}
          </button>
        );
      })}
    </div>
  );
}
