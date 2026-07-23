# OkHttp checks for these optional TLS providers at runtime. Tap does not
# package them, and Android's default TLS stack does not require them.
-dontwarn org.bouncycastle.**
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**
