/**
	Multi-threaded task pool implementation.

	Copyright: © 2012-2020 Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.core.taskpool;

import vibe.core.concurrency : isWeaklyIsolated;
import vibe.core.core : exitEventLoop, isCallable, isMethod, isNothrowCallable,
	isNothrowMethod, logicalProcessorCount, runEventLoop, runTask, runTask_internal;
import vibe.core.log;
import vibe.core.sync : ManualEvent, VibeSyncMonitor = Monitor, createSharedManualEvent, createMonitor;
import vibe.core.task : Task, TaskFuncInfo, TaskSettings, callWithMove;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.traits : isFunctionPointer;


/** Implements a shared, multi-threaded task pool.
*/
shared final class TaskPool {
	private {
		struct State {
			WorkerThread[] threads;
			TaskQueue queue;
			bool term;
		}
		VibeSyncMonitor!(State, shared(Mutex)) m_state;
		shared(ManualEvent) m_signal;
		immutable size_t m_threadCount;
	}

	/** Creates a new task pool with the specified number of threads.

		Params:
			thread_count = The number of worker threads to create
	*/
	this(size_t thread_count = logicalProcessorCount())
	@safe nothrow {
		import std.format : format;

		m_threadCount = thread_count;
		m_signal = createSharedManualEvent();
		m_state = createMonitor!State(new shared Mutex);

		with (m_state.lock) {
			queue.setup();
			threads.length = thread_count;
			foreach (i; 0 .. thread_count) {
				WorkerThread thr;
				() @trusted nothrow {
					thr = new WorkerThread(this);
					try thr.name = format("vibe-%s", i);
					catch (Exception e) logException(e, "Failed to set worker thread name");
					thr.start();
				} ();
				threads[i] = thr;
			}
		}
	}

	/** Returns the number of worker threads.
	*/
	@property size_t threadCount() const shared nothrow { return m_threadCount; }

	/** Instructs all worker threads to terminate and waits until all have
		finished.
	*/
	void terminate()
	@safe nothrow {
		m_state.lock.term = true;
		m_signal.emit();

		while (true) {
			WorkerThread th;
			with (m_state.lock)
				if (threads.length) {
					th = threads[0];
					threads = threads[1 .. $];
				}
			if (!th) break;

			if (th is Thread.getThis())
				continue;

			() @trusted {
				try th.join();
				catch (Exception e) {
					logWarn("Failed to wait for worker thread exit: %s", e.msg);
				}
			} ();
		}

		size_t cnt = m_state.lock.queue.length;
		if (cnt > 0) logWarn("There were still %d worker tasks pending at exit.", cnt);
	}

	/** Instructs all worker threads to terminate as soon as all tasks have
		been processed and waits for them to finish.
	*/
	void join()
	@safe nothrow {
		assert(false, "TODO!");
	}

	/** Runs a new asynchronous task in a worker thread.

		Only function pointers with weakly isolated arguments are allowed to be
		able to guarantee thread-safety.
	*/
	void runTask(FT, ARGS...)(FT func, auto ref ARGS args)
		if (isFunctionPointer!FT)
	{
		foreach (T; ARGS) static assert(isWeaklyIsolated!T, "Argument type "~T.stringof~" is not safe to pass between threads.");
		runTask_unsafe(TaskSettings.init, func, args);
	}
	/// ditto
	void runTask(alias method, T, ARGS...)(shared(T) object, auto ref ARGS args)
		if (is(typeof(__traits(getMember, object, __traits(identifier, method)))))
	{
		foreach (T; ARGS) static assert(isWeaklyIsolated!T, "Argument type "~T.stringof~" is not safe to pass between threads.");
		auto func = &__traits(getMember, object, __traits(identifier, method));
		runTask_unsafe(TaskSettings.init, func, args);
	}
	/// ditto
	void runTask(FT, ARGS...)(TaskSettings settings, FT func, auto ref ARGS args)
		if (isFunctionPointer!FT)
	{
		foreach (T; ARGS) static assert(isWeaklyIsolated!T, "Argument type "~T.stringof~" is not safe to pass between threads.");
		runTask_unsafe(settings, func, args);
	}
	/// ditto
	void runTask(alias method, T, ARGS...)(TaskSettings settings, shared(T) object, auto ref ARGS args)
		if (is(typeof(__traits(getMember, object, __traits(identifier, method)))))
	{
		foreach (T; ARGS) static assert(isWeaklyIsolated!T, "Argument type "~T.stringof~" is not safe to pass between threads.");
		auto func = &__traits(getMember, object, __traits(identifier, method));
		runTask_unsafe(settings, func, args);
	}

	/** Runs a new asynchronous task in a worker thread, returning the task handle.

		This function will yield and wait for the new task to be created and started
		in the worker thread, then resume and return it.

		Only function pointers with weakly isolated arguments are allowed to be
		able to guarantee thread-safety.
	*/
	Task runTaskH(FT, ARGS...)(FT func, auto ref ARGS args)
		if (isFunctionPointer!FT && isNothrowCallable!(FT, ARGS))
	{
		foreach (T; ARGS) static assert(isWeaklyIsolated!T, "Argument type "~T.stringof~" is not safe to pass between threads.");

		// workaround for runWorkerTaskH to work when called outside of a task
		if (Task.getThis() == Task.init) {
			Task ret;
			.runTask((FT func, ARGS args) nothrow { ret = doRunTaskH(TaskSettings.init, func, args); }, func, args).joinUninterruptible();
			return ret;
		} else return doRunTaskH(TaskSettings.init, func, args);
	}
	/// ditto
	Task runTaskH(alias method, T, ARGS...)(shared(T) object, auto ref ARGS args)
		if (isNothrowMethod!(shared(T), method, ARGS))
	{
		static void wrapper()(shared(T) object, ref ARGS args) {
			__traits(getMember, object, __traits(identifier, method))(args);
		}
		return runTaskH(&wrapper!(), object, args);
	}
	/// ditto
	Task runTaskH(FT, ARGS...)(TaskSettings settings, FT func, auto ref ARGS args)
		if (isFunctionPointer!FT && isNothrowCallable!(FT, ARGS))
	{
		foreach (T; ARGS) static assert(isWeaklyIsolated!T, "Argument type "~T.stringof~" is not safe to pass between threads.");

		// workaround for runWorkerTaskH to work when called outside of a task
		if (Task.getThis() == Task.init) {
			Task ret;
			.runTask((TaskSettings settings, FT func, ARGS args) nothrow { ret = doRunTaskH(settings, func, args); }, settings, func, args).joinUninterruptible();
			return ret;
		} else return doRunTaskH(settings, func, args);
	}
	/// ditto
	Task runTaskH(alias method, T, ARGS...)(TaskSettings settings, shared(T) object, auto ref ARGS args)
		if (isNothrowMethod!(shared(T), method, ARGS))
	{
		static void wrapper()(shared(T) object, ref ARGS args) {
			__traits(getMember, object, __traits(identifier, method))(args);
		}
		return runTaskH(settings, &wrapper!(), object, args);
	}

	// NOTE: needs to be a separate function to avoid recursion for the
	//       workaround above, which breaks @safe inference
	private Task doRunTaskH(FT, ARGS...)(TaskSettings settings, FT func, ref ARGS args)
		if (isFunctionPointer!FT)
	{
		import std.typecons : Typedef;
		import vibe.core.channel : Channel, createChannel;

		foreach (T; ARGS) static assert(isWeaklyIsolated!T, "Argument type "~T.stringof~" is not safe to pass between threads.");

		alias PrivateTask = Typedef!(Task, Task.init, __PRETTY_FUNCTION__);

		auto ch = createChannel!Task();

		static void taskFun(Channel!Task ch, FT func, ARGS args) {
			try ch.put(Task.getThis());
			catch (Exception e) assert(false, e.msg);
			mixin(callWithMove!ARGS("func", "args"));
		}
		runTask_unsafe(settings, &taskFun, ch, func, args);

		Task ret;
		if (!ch.tryConsumeOne(ret))
			assert(false, "Channel closed without passing a task handle!?");
		ch.close();
		return ret;
	}


	/** Runs a new asynchronous task in all worker threads concurrently.

		This function is mainly useful for long-living tasks that distribute their
		work across all CPU cores. Only function pointers with weakly isolated
		arguments are allowed to be able to guarantee thread-safety.

		The number of tasks started is guaranteed to be equal to
		`threadCount`.
	*/
	void runTaskDist(FT, ARGS...)(FT func, auto ref ARGS args)
		if (isFunctionPointer!FT && isNothrowCallable!(FT, ARGS))
	{
		foreach (T; ARGS) static assert(isWeaklyIsolated!T, "Argument type "~T.stringof~" is not safe to pass between threads.");
		runTaskDist_unsafe(TaskSettings.init, func, args);
	}
	/// ditto
	void runTaskDist(alias method, T, ARGS...)(shared(T) object, auto ref ARGS args)
		if (isNothrowMethod!(shared(T), method, ARGS))
	{
		auto func = &__traits(getMember, object, __traits(identifier, method));
		foreach (T; ARGS) static assert(isWeaklyIsolated!T, "Argument type "~T.stringof~" is not safe to pass between threads.");

		runTaskDist_unsafe(TaskSettings.init, func, args);
	}
	/// ditto
	void runTaskDist(FT, ARGS...)(TaskSettings settings, FT func, auto ref ARGS args)
		if (isFunctionPointer!FT && isNothrowCallable!(FT, ARGS))
	{
		foreach (T; ARGS) static assert(isWeaklyIsolated!T, "Argument type "~T.stringof~" is not safe to pass between threads.");
		runTaskDist_unsafe(settings, func, args);
	}
	/// ditto
	void runTaskDist(alias method, T, ARGS...)(TaskSettings settings, shared(T) object, auto ref ARGS args)
		if (isNothrowMethod!(shared(T), method, ARGS))
	{
		auto func = &__traits(getMember, object, __traits(identifier, method));
		foreach (T; ARGS) static assert(isWeaklyIsolated!T, "Argument type "~T.stringof~" is not safe to pass between threads.");

		runTaskDist_unsafe(settings, func, args);
	}

	/** Runs a new asynchronous task in all worker threads and returns the handles.

		`on_handle` is an alias to a callble that takes a `Task` as its only
		argument and is called for every task instance that gets created.

		See_also: `runTaskDist`
	*/
	void runTaskDistH(HCB, FT, ARGS...)(scope HCB on_handle, FT func, auto ref ARGS args)
		if (!is(HCB == TaskSettings))
	{
		runTaskDistH(TaskSettings.init, on_handle, func, args);
	}
	/// ditto
	void runTaskDistH(HCB, FT, ARGS...)(TaskSettings settings, scope HCB on_handle, FT func, auto ref ARGS args)
	{
		import vibe.core.channel : Channel, createChannel;

		// TODO: support non-copyable argument types using .move
		auto ch = createChannel!Task;

		static void call(Channel!Task ch, FT func, ARGS args) {
			try ch.put(Task.getThis());
			catch (Exception e) assert(false, e.msg);
			func(args);
		}
		runTaskDist(settings, &call, ch, func, args);

		foreach (i; 0 .. this.threadCount)
			on_handle(ch.consumeOne());

		ch.close();
	}

	private void runTask_unsafe(CALLABLE, ARGS...)(TaskSettings settings, CALLABLE callable, ref ARGS args)
	{
		import std.traits : ParameterTypeTuple;
		import vibe.internal.traits : areConvertibleTo;
		import vibe.internal.typetuple;

		alias FARGS = ParameterTypeTuple!CALLABLE;
		static assert(areConvertibleTo!(Group!ARGS, Group!FARGS),
			"Cannot convert arguments '"~ARGS.stringof~"' to function arguments '"~FARGS.stringof~"'.");

		m_state.lock.queue.put(settings, callable, args);
		m_signal.emitSingle();
	}

	private void runTaskDist_unsafe(CALLABLE, ARGS...)(TaskSettings settings, ref CALLABLE callable, ARGS args) // NOTE: no ref for args, to disallow non-copyable types!
	{
		import std.traits : ParameterTypeTuple;
		import vibe.internal.traits : areConvertibleTo;
		import vibe.internal.typetuple;

		alias FARGS = ParameterTypeTuple!CALLABLE;
		static assert(areConvertibleTo!(Group!ARGS, Group!FARGS),
			"Cannot convert arguments '"~ARGS.stringof~"' to function arguments '"~FARGS.stringof~"'.");

		{
			auto st = m_state.lock;
			foreach (thr; st.threads) {
				// create one TFI per thread to properly account for elaborate assignment operators/postblit
				thr.m_queue.put(settings, callable, args);
			}
		}
		m_signal.emit();
	}
}

private final class WorkerThread : Thread {
	private {
		shared(TaskPool) m_pool;
		TaskQueue m_queue;
	}

	this(shared(TaskPool) pool)
	nothrow {
		m_pool = pool;
		m_queue.setup();
		super(&main);
	}

	private void main()
	nothrow {
		import core.stdc.stdlib : abort;
		import core.exception : InvalidMemoryOperationError;
		import std.encoding : sanitize;

		try {
			if (m_pool.m_state.lock.term) return;
			logDebug("entering worker thread");

			// There is an issue where a task that periodically calls yield()
			// but otherwise only performs a CPU computation will cause a
			// call to runEventLoopOnce() or yield() called from the global
			// thread context to not return before the task is finished. For
			// this reason we start a task here, which in turn is scheduled
			// properly together with such a task, and also is schduled
			// according to the task priorities.
			runTask(&handleWorkerTasks).joinUninterruptible();

			logDebug("Worker thread exit.");
		} catch (Throwable th) {
			th.logException!(LogLevel.fatal)("Worker thread terminated due to uncaught error");
			abort();
		}
	}

	private void handleWorkerTasks()
	nothrow @safe {
		import std.algorithm.iteration : filter;
		import std.algorithm.mutation : swap;
		import std.algorithm.searching : count;
		import std.array : array;

		logTrace("worker thread enter");
		TaskFuncInfo taskfunc;
		auto emit_count = m_pool.m_signal.emitCount;
		while(true) {
			with (m_pool.m_state.lock) {
				logTrace("worker thread check");

				if (term) break;

				if (m_queue.consume(taskfunc)) {
					logTrace("worker thread got specific task");
				} else if (queue.consume(taskfunc)) {
					logTrace("worker thread got unspecific task");
				}
			}

			if (taskfunc.func !is null)
				.runTask_internal!((ref tfi) { swap(tfi, taskfunc); });
			else emit_count = m_pool.m_signal.waitUninterruptible(emit_count);
		}

		logTrace("worker thread exit");

		if (!m_queue.empty)
			logWarn("Worker thread shuts down with specific worker tasks left in its queue.");

		with (m_pool.m_state.lock) {
			threads = threads.filter!(t => t !is this).array;
			if (threads.length > 0 && !queue.empty)
				logWarn("Worker threads shut down with worker tasks still left in the queue.");
		}
	}
}

private struct TaskQueue {
nothrow @safe:
	// TODO: avoid use of GC

	import vibe.internal.array : FixedRingBuffer;
	FixedRingBuffer!TaskFuncInfo* m_queue;

	void setup()
	{
		m_queue = new FixedRingBuffer!TaskFuncInfo;
	}

	@property bool empty() const { return m_queue.empty; }

	@property size_t length() const { return m_queue.length; }

	void put(CALLABLE, ARGS...)(TaskSettings settings, ref CALLABLE c, ref ARGS args)
	{
		import std.algorithm.comparison : max;
		if (m_queue.full) m_queue.capacity = max(16, m_queue.capacity * 3 / 2);
		assert(!m_queue.full);

		m_queue.peekDst[0].settings = settings;
		m_queue.peekDst[0].set(c, args);
		m_queue.putN(1);
	}

	bool consume(ref TaskFuncInfo tfi)
	{
		import std.algorithm.mutation : swap;

		if (m_queue.empty) return false;
		swap(tfi, m_queue.front);
		m_queue.popFront();
		return true;
	}
}
