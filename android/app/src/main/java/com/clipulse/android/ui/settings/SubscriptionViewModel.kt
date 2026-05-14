package com.clipulse.android.ui.settings

import android.app.Activity
import androidx.lifecycle.ViewModel
import com.android.billingclient.api.ProductDetails
import com.clipulse.android.billing.BillingManager
import com.clipulse.android.billing.SubscriptionState
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.StateFlow
import javax.inject.Inject

@HiltViewModel
class SubscriptionViewModel @Inject constructor(
    private val billingManager: BillingManager,
) : ViewModel() {

    val state: StateFlow<SubscriptionState> = billingManager.state

    init {
        billingManager.connect()
    }

    fun purchase(activity: Activity, productDetails: ProductDetails) {
        billingManager.purchase(activity, productDetails)
    }

    fun restore() {
        billingManager.restorePurchases()
    }

    // v1.20.1 C3: DO NOT call billingManager.disconnect() in onCleared() — the
    // BillingManager is an @Singleton at app scope. Disconnecting it when the
    // user navigates away from the Subscription screen would destroy the
    // shared billing client for every other ViewModel that depends on it
    // (e.g. the paywall gate in OverviewViewModel). The billing client is
    // managed at process lifetime; the OS releases it on process death.
}
