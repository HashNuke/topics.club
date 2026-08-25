export default function ChannelDirectoryFeedback({error, joinError, onRefresh}) {
  return (
    <>
      {error && (
        <div className="mb-4 flex flex-col gap-3 rounded-md border border-rose-400/30 bg-rose-400/5 p-4 sm:flex-row sm:items-center sm:justify-between" role="alert">
          <div>
            <div className="text-sm font-semibold text-rose-200">The channel list did not load</div>
            <p className="mt-1 text-sm text-slate-400">{error}</p>
          </div>
          <button className="shrink-0 self-start rounded-md border border-rose-300/40 px-3 py-1.5 text-sm font-semibold text-rose-100 transition hover:border-rose-200 hover:text-white" onClick={onRefresh} type="button">
            Try again
          </button>
        </div>
      )}

      {joinError && (
        <div className="mb-4 rounded-md border border-amber-300/30 bg-amber-300/5 p-4" role="alert">
          <div className="text-sm font-semibold text-amber-100">Channel was not joined</div>
          <p className="mt-1 text-sm text-slate-400">{joinError}</p>
        </div>
      )}
    </>
  )
}
