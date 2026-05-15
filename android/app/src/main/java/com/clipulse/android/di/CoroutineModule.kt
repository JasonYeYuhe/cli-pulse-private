package com.clipulse.android.di

import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import javax.inject.Qualifier
import javax.inject.Singleton

/**
 * Process-scoped CoroutineScope qualifier.
 *
 * v1.21 E5: short-lived components such as FirebaseMessagingService should not
 * spawn `CoroutineScope(Dispatchers.IO).launch { ... }` directly — the
 * resulting scope has no owner, leaks the launched coroutine across service
 * destruction, and cannot be cancelled if the user signs out / app is killed.
 *
 * Inject `@ApplicationScope CoroutineScope` instead. The scope:
 *   * uses a SupervisorJob so one failing child does not cascade
 *   * dispatches on IO by default
 *   * survives for the lifetime of the Application process, which is the
 *     correct boundary for FCM token uploads / fire-and-forget telemetry.
 */
@Qualifier
@Retention(AnnotationRetention.BINARY)
annotation class ApplicationScope

@Module
@InstallIn(SingletonComponent::class)
object CoroutineModule {

    @Provides
    @Singleton
    @ApplicationScope
    fun provideApplicationScope(): CoroutineScope =
        CoroutineScope(SupervisorJob() + Dispatchers.IO)
}
