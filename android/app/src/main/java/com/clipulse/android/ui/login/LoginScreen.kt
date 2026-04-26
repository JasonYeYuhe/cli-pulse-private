package com.clipulse.android.ui.login

import android.content.Intent
import android.net.Uri
import android.util.Log
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.credentials.CredentialManager
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.hilt.navigation.compose.hiltViewModel
import com.google.android.libraries.identity.googleid.GetGoogleIdOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import com.clipulse.android.MainActivity
import com.clipulse.android.R
import com.clipulse.android.data.remote.OAuthDeepLinkCallback
import com.clipulse.android.data.remote.OAuthDeepLinkNotice
import com.clipulse.android.data.remote.OAuthDeepLinkNoticeReason
import kotlinx.coroutines.launch

@Composable
fun LoginScreen(
    viewModel: LoginViewModel = hiltViewModel(),
    loginCallback: OAuthDeepLinkCallback? = null,
    loginNotice: OAuthDeepLinkNotice? = null,
    onLoggedIn: () -> Unit,
) {
    val state by viewModel.state.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var oauthNoticeMessage by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) { viewModel.tryRestoreSession() }
    LaunchedEffect(state.isLoggedIn) {
        if (state.isLoggedIn) onLoggedIn()
    }

    // Handle deep-link OAuth callback (durable — verifier + state already validated by MainActivity).
    LaunchedEffect(loginCallback) {
        val cb = loginCallback ?: return@LaunchedEffect
        viewModel.exchangeOAuthCode(cb.code, cb.codeVerifier)
        (context as? MainActivity)?.consumePendingCallback()
    }

    // Surface a non-success deep-link outcome (cancel / error / state mismatch / malformed)
    // as an inline error. Pending-flow record was already cleared by MainActivity.
    LaunchedEffect(loginNotice) {
        val notice = loginNotice ?: return@LaunchedEffect
        val resId = when (notice.reason) {
            OAuthDeepLinkNoticeReason.CANCELLED -> R.string.oauth_sign_in_cancelled
            OAuthDeepLinkNoticeReason.FAILED -> R.string.oauth_sign_in_failed
            OAuthDeepLinkNoticeReason.STATE_MISMATCH -> R.string.oauth_sign_in_state_mismatch
            OAuthDeepLinkNoticeReason.MALFORMED -> R.string.oauth_sign_in_malformed
        }
        oauthNoticeMessage = context.getString(resId)
        (context as? MainActivity)?.consumePendingNotice()
    }

    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var otpCode by remember { mutableStateOf("") }
    var showPasswordLogin by remember { mutableStateOf(false) }

    Surface(
        modifier = Modifier.fillMaxSize(),
        color = MaterialTheme.colorScheme.background,
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Text(
                stringResource(R.string.app_name),
                style = MaterialTheme.typography.headlineLarge,
                color = MaterialTheme.colorScheme.primary,
            )
            Spacer(Modifier.height(8.dp))
            Text(
                stringResource(R.string.auth_tagline),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(48.dp))

            if (state.isLoading) {
                CircularProgressIndicator()
                return@Column
            }

            oauthNoticeMessage?.let { message ->
                Text(
                    message,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(bottom = 16.dp),
                )
            }

            state.error?.let { error ->
                Text(
                    error,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(bottom = 16.dp),
                )
            }

            if (state.showOtpInput) {
                // OTP verification
                Text(
                    stringResource(R.string.auth_otp_sent_to, state.otpEmail),
                    style = MaterialTheme.typography.bodyMedium,
                )
                Spacer(Modifier.height(16.dp))
                OutlinedTextField(
                    value = otpCode,
                    onValueChange = { otpCode = it },
                    label = { Text(stringResource(R.string.auth_otp_code_label)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(16.dp))
                Button(
                    onClick = { viewModel.verifyOTP(otpCode) },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = otpCode.isNotBlank(),
                ) {
                    Text(stringResource(R.string.verify))
                }
            } else if (showPasswordLogin) {
                // Password login
                OutlinedTextField(
                    value = email,
                    onValueChange = { email = it },
                    label = { Text(stringResource(R.string.auth_email_label)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(12.dp))
                OutlinedTextField(
                    value = password,
                    onValueChange = { password = it },
                    label = { Text(stringResource(R.string.auth_password_label)) },
                    visualTransformation = PasswordVisualTransformation(),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(16.dp))
                Button(
                    onClick = { viewModel.signInWithPassword(email, password) },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = email.isNotBlank() && password.isNotBlank(),
                ) {
                    Text(stringResource(R.string.sign_in_button))
                }
                Spacer(Modifier.height(8.dp))
                TextButton(onClick = { showPasswordLogin = false }) {
                    Text(stringResource(R.string.auth_back_to_email))
                }
            } else {
                // Email OTP flow (primary)
                OutlinedTextField(
                    value = email,
                    onValueChange = { email = it },
                    label = { Text(stringResource(R.string.auth_email_label)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(16.dp))
                Button(
                    onClick = { viewModel.sendOTP(email) },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = email.contains("@"),
                ) {
                    Text(stringResource(R.string.send_verification_code))
                }
                Spacer(Modifier.height(24.dp))
                HorizontalDivider()
                Spacer(Modifier.height(24.dp))

                // Google Sign-In via Credential Manager
                OutlinedButton(
                    onClick = {
                        scope.launch {
                            try {
                                val googleIdOption = GetGoogleIdOption.Builder()
                                    .setFilterByAuthorizedAccounts(false)
                                    .setServerClientId(com.clipulse.android.BuildConfig.GOOGLE_WEB_CLIENT_ID)
                                    .build()
                                val request = GetCredentialRequest.Builder()
                                    .addCredentialOption(googleIdOption)
                                    .build()
                                val credentialManager = CredentialManager.create(context)
                                val result = credentialManager.getCredential(context, request)
                                val credential = result.credential
                                val googleIdToken = GoogleIdTokenCredential.createFrom(credential.data)
                                viewModel.signInWithGoogle(
                                    idToken = googleIdToken.idToken,
                                    name = googleIdToken.displayName,
                                    email = googleIdToken.id,
                                )
                            } catch (_: GetCredentialCancellationException) {
                                // User cancelled
                            } catch (e: Exception) {
                                Log.w("LoginScreen", "Google Sign-In failed", e)
                            }
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(stringResource(R.string.sign_in_google))
                }
                Spacer(Modifier.height(12.dp))

                // GitHub Sign-In via Supabase OAuth PKCE
                OutlinedButton(
                    onClick = {
                        val url = viewModel.startOAuthLogin("github")
                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                    },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(stringResource(R.string.sign_in_github))
                }
                Spacer(Modifier.height(12.dp))
                TextButton(onClick = { showPasswordLogin = true }) {
                    Text(stringResource(R.string.sign_in_password))
                }
                Spacer(Modifier.height(24.dp))
                TextButton(onClick = {
                    viewModel.enterDemoMode()
                }) {
                    Text(stringResource(R.string.try_demo), color = MaterialTheme.colorScheme.tertiary)
                }
            }
        }
    }
}
