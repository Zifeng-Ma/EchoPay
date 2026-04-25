// import 'dart:async';
// import 'dart:convert';
// import 'package:flutter/services.dart'; // <-- Added for PlatformException
// import 'package:google_sign_in/google_sign_in.dart';
// import 'package:logger/logger.dart';
// import 'package:supabase_flutter/supabase_flutter.dart';
// import 'package:sign_in_with_apple/sign_in_with_apple.dart';
// import 'package:crypto/crypto.dart';

// final logger = Logger();

// class AuthService {
//   final supabase = Supabase.instance.client;
  
//   Future<void> deleteCurrentUser() async {
//       try {
//         // 1. Let the Supabase package automatically handle the tokens and refreshing!
//         await supabase.functions.invoke('delete-user');

//         // 2. Immediately sign the user out locally so the UI updates
//         await signOut();
        
//       } catch (e) {
//         throw Exception('Failed to delete account: $e');
//       }
//     }
    
//   Future<AuthResponse> signUpwithEmail(String email, String password) async {
//     try {
//       return await supabase.auth.signUp(email: email, password: password);
//     } on AuthException catch (e) {
//       logger.e('Supabase Auth Error: ${e.message}');
//       rethrow; // Preserves the clean Supabase message for the UI to display
//     } catch (e) {
//       logger.e('Unexpected Sign Up Error: $e');
//       throw Exception('An unexpected error occurred during sign up.');
//     }
//   }

//   Future<AuthResponse> signInwithEmail(String email, String password) async {
//     try {
//       return await supabase.auth.signInWithPassword(email: email, password: password);
//     } on AuthException catch (e) {
//       logger.e('Supabase Auth Error: ${e.message}');
//       rethrow;
//     } catch (e) {
//       logger.e('Unexpected Sign In Error: $e');
//       throw Exception('An unexpected error occurred during sign in.');
//     }
//   }

//   Future<AuthResponse> signInWithApple() async {
//     try {
//       final rawNonce = supabase.auth.generateRawNonce();
//       final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();

//       final credential = await SignInWithApple.getAppleIDCredential(
//         scopes: [
//           AppleIDAuthorizationScopes.email,
//           AppleIDAuthorizationScopes.fullName,
//         ],
//         nonce: hashedNonce,
//       );

//       final idToken = credential.identityToken;
//       if (idToken == null) {
//         throw const AuthException('Could not find ID Token from generated credential.');
//       }

//       return await supabase.auth.signInWithIdToken(
//         provider: OAuthProvider.apple,
//         idToken: idToken,
//         nonce: rawNonce,
//       );
//     } on SignInWithAppleAuthorizationException catch (e) {
//       logger.e('Apple Sign In Error: ${e.code} - ${e.message}');
      
//       // If the user simply closed the Apple popup, we throw a specific flag
//       if (e.code == AuthorizationErrorCode.canceled) {
//         throw Exception('CANCELED_BY_USER');
//       }
//       // Otherwise, throw the actual Apple error
//       throw Exception('Apple Sign In failed: ${e.message}');
//     } catch (e) {
//       logger.e('Unexpected Apple Sign In Error: $e');
//       throw Exception('An unexpected error occurred during Apple Sign In.');
//     }
//   }

//   Future<AuthResponse> signInWithGoogle() async {
//     try {
//       const iosClientId = '942759866146-1e2hhp30nj6nli7hfaecnf4pv2i1dr6m.apps.googleusercontent.com';

//       final GoogleSignIn signIn = GoogleSignIn.instance;
      
//       // Wait for initialization
//       await signIn.initialize(clientId: iosClientId);

//       // Perform the sign in
//       final googleAccount = await signIn.authenticate();
      

//       final googleAuthorization = await googleAccount.authorizationClient.authorizationForScopes([]);
//       final googleAuthentication = googleAccount.authentication;
//       final idToken = googleAuthentication.idToken;
//       final accessToken = googleAuthorization?.accessToken;

//       if (idToken == null) {
//         throw const AuthException('No ID Token found from Google Auth.');
//       }

//       return await supabase.auth.signInWithIdToken(
//         provider: OAuthProvider.google,
//         idToken: idToken,
//         accessToken: accessToken,
//       );
//     } on PlatformException catch (e) {
//       logger.e('Google Sign In Platform Error: ${e.code} - ${e.message}');
//       if (e.code == 'sign_in_canceled') {
//         throw Exception('CANCELED_BY_USER');
//       }
//       throw Exception('Google Sign In failed: ${e.message}');
//     } catch (e) {
//       logger.e('Unexpected Google Sign In Error: $e');
//       if (e.toString().contains('CANCELED_BY_USER')) rethrow; // Pass cancellation up
//       throw Exception('An unexpected error occurred during Google Sign In.');
//     }
//   }

//   Future<void> signOut() async {
//     try {
//       await supabase.auth.signOut();
//     } catch (e) {
//       logger.e('Sign out error: $e');
//       throw Exception('Failed to sign out. Please try again.');
//     }
//   }
// }