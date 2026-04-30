package com.clipulse.android

import io.mockk.unmockkAll
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.DisposableHandle
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.InternalCoroutinesApi
import kotlinx.coroutines.test.TestDispatcher
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.rules.TestWatcher
import org.junit.runner.Description
import kotlin.coroutines.CoroutineContext

/**
 * Installs a `TestDispatcher` as `Dispatchers.Main` for ViewModel tests
 * and tears it down after each test.
 *
 * The dispatcher is wrapped in [MainPassthroughDispatcher] (a plain
 * `CoroutineDispatcher` + `Delay`, not a `TestDispatcher`) so
 * `runTest`'s post-body drain does not advance Main's scheduler. This
 * prevents `viewModelScope.launch { while (true) { delay(...); … } }`
 * auto-refresh loops from being pumped during runTest cleanup.
 *
 * `unmockkAll()` runs on teardown to clear MockK state between tests.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class MainDispatcherRule(
    val testDispatcher: TestDispatcher = UnconfinedTestDispatcher(),
) : TestWatcher() {

    private val mainDispatcher = MainPassthroughDispatcher(testDispatcher)

    override fun starting(description: Description) {
        Dispatchers.setMain(mainDispatcher)
    }

    override fun finished(description: Description) {
        Dispatchers.resetMain()
        unmockkAll()
    }
}

/**
 * Forwarding dispatcher that delegates to a `TestDispatcher` without
 * itself being one, so `runTest` does not treat `Dispatchers.Main` as
 * a `TestDispatcher` for drain purposes.
 */
@OptIn(ExperimentalCoroutinesApi::class, InternalCoroutinesApi::class)
private class MainPassthroughDispatcher(
    private val delegate: TestDispatcher,
) : CoroutineDispatcher(), Delay {

    override fun isDispatchNeeded(context: CoroutineContext): Boolean =
        delegate.isDispatchNeeded(context)

    override fun dispatch(context: CoroutineContext, block: Runnable) {
        delegate.dispatch(context, block)
    }

    override fun dispatchYield(context: CoroutineContext, block: Runnable) {
        delegate.dispatchYield(context, block)
    }

    override fun scheduleResumeAfterDelay(
        timeMillis: Long,
        continuation: CancellableContinuation<Unit>,
    ) {
        delegate.scheduleResumeAfterDelay(timeMillis, continuation)
    }

    override fun invokeOnTimeout(
        timeMillis: Long,
        block: Runnable,
        context: CoroutineContext,
    ): DisposableHandle = delegate.invokeOnTimeout(timeMillis, block, context)
}
