import { t } from '../i18n';
import React from 'react';
import { Play, Film, Download, RefreshCw, Zap } from './icons';

const onlinePhaseLabel = phase => phase === 'preparing' ? '正在连接片源…' : phase === 'queued' ? '等待其他视频转换完成…'
  : phase === 'transcoding' ? '正在转换为可播放格式…' : phase === 'decrypting' ? '正在准备播放…' : '正在缓冲在线播放…';

// Everything drawn over the video while it cannot play or is recovering. Pure view of Player state.
export default function PlayerStageStatus(props) {
  const {
    mobile, canPlay, holdingFrame, playbackError, current, episodes, currentIndex, onlineProgress,
    readingLocal, waitingFor, playbackRequested, qualityLoading, frameWaiting, mediaBuffering,
    compatProgress, decodeFailed, compatError, softwareDecode, videoPaused, showLocalChoice, showTranscode,
    onRetry, onChooseLocal, onReconnect, onTranscode, onStop, onPlayCurrent, onPlayOnline, onDownload,
    onResume, onReload, onOpenSettings,
  } = props;
  const waitingEpisode = waitingFor != null ? episodes.find((e) => e.vid_index === waitingFor) : null;
  return (
    <>
      {!canPlay && (
        <div className={`player-placeholder${holdingFrame && !playbackError ? ' player-placeholder-over-frame' : ''}`} style={{ position: 'absolute', inset: 0, zIndex: 3 }}>
          {t(playbackError ? (
            <><Film size={34} /><p role="alert">{t(playbackError)}</p><div className="player-placeholder-actions">
              <button className="btn btn-primary" onClick={onRetry}>{t(current?.status === 'completed' ? '重试本集' : '重试本集（在线播放）')}</button>
              {showLocalChoice && <button className="btn btn-outline" onClick={onChooseLocal}>{t("播放已有本地文件")}</button>}
              {current?.vid && <button className="btn btn-outline" onClick={onReconnect}>{t("重新连接片源")}</button>}
              {showTranscode && <button className="btn btn-outline" onClick={onTranscode}>{t("转码后播放")}</button>}
            </div></>
          ) : onlineProgress && onlineProgress.vid && (!current || current.vid === onlineProgress.vid) ? (
            <>
              <RefreshCw size={30} className="spin" />
              <p>{t(onlinePhaseLabel(onlineProgress.phase))}</p>
              {!['preparing', 'queued'].includes(onlineProgress.phase) && <div className="player-wait-bar">
                <div className="player-wait-fill" style={{ width: `${onlineProgress.percent || 0}%` }} />
              </div>}
              <span className="player-placeholder-sub">
                {t(onlineProgress.phase === 'preparing' ? '获取可播放地址' : onlineProgress.phase === 'queued' ? '已排队，轮到本集后开始转换' : `${onlineProgress.percent || 0}%`)}
                {onlineProgress.total && !['transcoding', 'queued'].includes(onlineProgress.phase) ? ` · ${(onlineProgress.received / 1048576).toFixed(1)} / ${(onlineProgress.total / 1048576).toFixed(1)} MB` : ''}
                {onlineProgress.bytesPerSecond > 0 && onlineProgress.phase === 'downloading' ? ` · ${(onlineProgress.bytesPerSecond / 1048576).toFixed(1)} MB/s` : ''}
                {t(' · 不写入下载目录')}
              </span>
              <button className="btn btn-outline" onClick={() => onStop()}>{t("取消播放")}</button>
            </>
          ) : readingLocal ? (
            <><RefreshCw size={30} className="spin" /><p>{t("正在读取本机视频…")}</p></>
          ) : waitingFor != null ? (
            <>
              <RefreshCw size={30} className="spin" />
              <p>{t("第 {0} 集正在下载，完成后自动播放…", [waitingFor])}</p>
              {waitingEpisode && waitingEpisode.status === 'downloading' ? (
                <div className="player-wait-bar">
                  <div className="player-wait-fill" style={{ width: `${waitingEpisode.progress || 0}%` }} />
                </div>
              ) : null}
              <span className="player-placeholder-sub">{t("下载完成后继续本集；取消等待不会停止下载")}</span>
              <button className="btn btn-outline" onClick={() => onStop('已取消等待，下载会继续；可在下载管理查看')}>{t("取消等待")}</button>
            </>
          ) : current?.locked || (episodes.length > 0 && episodes.every((ep) => ep.locked)) ? (
            <><Film size={34} /><p>{t("需在来源平台解锁后观看")}</p><span className="player-placeholder-sub">{t("本应用不提供解锁")}</span></>
          ) : !playbackRequested && current ? (
            <><Film size={34} /><p>{t("第 {0} 集 · 等待播放", [current.vid_index])}</p>
              <button className="btn btn-primary" onClick={onPlayCurrent}>
                <Play size={15} />{t("播放本集")}</button>
              <span className="player-placeholder-sub">{t("点击后继续观看，也可选择其他集数")}</span>
            </>
          ) : current ? (
            <>
              <Film size={34} />
              <p>{t("第 {0} 集 · {1}", [current.vid_index, t(current.status === 'downloading' ? '正在下载' : current.status === 'pending' ? '排队中' : '尚未下载')])}
              </p>
              {current.status === 'downloading' && (
                <div className="player-wait-bar">
                  <div className="player-wait-fill" style={{ width: `${current.progress || 0}%` }} />
                </div>
              )}
              <div className="player-placeholder-actions">
                <button className="btn btn-primary" onClick={() => onPlayOnline(current.vid_index)}>
                  <Play size={15} />{t("在线播放（不下载）")}</button>
                <button className="btn btn-outline" disabled={qualityLoading} onClick={() => onDownload(current.vid_index)}>
                  <Download size={15} />{t("下载本集")}</button>
              </div>
              <span className="player-placeholder-sub">{t("在线播放不保存到下载目录，准备产生的临时文件会自动清理")}</span>
            </>
          ) : (
            <>
              <Film size={34} />
              <p>{t("请选择一集开始播放")}</p>
            </>
          ))}
        </div>
      )}

      {canPlay && holdingFrame && frameWaiting && !mediaBuffering && !compatProgress && !decodeFailed && (
        <div className="compat-overlay" role="status">
          <Film size={26} />
          <p>{t(softwareDecode && videoPaused ? '已暂停，继续播放后显示新画面' : '正在等待新画面…')}</p>
          <div className="player-placeholder-actions">
            {softwareDecode && videoPaused && <button className="btn btn-primary" onClick={onResume}>{t("继续播放")}</button>}
            <button className="btn btn-outline" onClick={onReload}>{t("重新加载本集")}</button>
            <button className="btn btn-outline" onClick={() => onStop()}>{t("取消播放")}</button>
          </div>
        </div>
      )}

      {canPlay && mediaBuffering && !compatProgress && (
        <div className="compat-overlay" role="status">
          <RefreshCw size={26} className="spin" /><p>{t("正在加载视频…")}</p>
          <button className="btn btn-outline" onClick={() => onStop()}>{t("取消播放")}</button>
        </div>
      )}

      {/* 兼容模式浮层：解码失败提示 / 转码进度 */}
      {compatProgress && compatProgress.vidIndex === currentIndex && (
        <div className="compat-overlay">
          <RefreshCw size={26} className="spin" />
          <p>{t("正在转码为兼容格式（H.264）…")}</p>
          <div className="player-wait-bar">
            <div className="player-wait-fill" style={{ width: `${compatProgress.percent || 0}%` }} />
          </div>
          <span className="compat-overlay-sub">
            {compatProgress.percent || 0}{t("% · 正在处理当前视频，完成后切换到兼容片源")}</span>
          <button className="btn btn-outline" onClick={() => onStop('转码已取消，可重试本集继续观看')}>{t("取消转码")}</button>
        </div>
      )}

      {!compatProgress && decodeFailed && canPlay && (
        <div className="compat-overlay">
          <Film size={30} />
          <p>{t("当前片源暂时无法播放")}</p>
          <span className="compat-overlay-sub" role={compatError ? 'alert' : undefined}>
            {t(compatError || (mobile ? '请重新连接片源，或在播放设置中更换画质。安卓兼容转码尚未接入。' : '请先重新连接片源；若仍有画面或格式问题，可尝试转码为 H.264 兼容格式。'))}
          </span>
          <div className="player-placeholder-actions">
            <button className="btn btn-primary" onClick={onRetry}>{t("重试本集")}</button>
            <button className="btn btn-outline" onClick={onReconnect}>{t("重新连接片源")}</button>
            {!mobile && <button className="btn btn-outline" onClick={onTranscode}>
              <Zap size={15} />{t("重新转码后播放")}</button>}
            <button className="btn btn-outline" onClick={onOpenSettings}>{t("播放设置")}</button>
          </div>
        </div>
      )}
    </>
  );
}
