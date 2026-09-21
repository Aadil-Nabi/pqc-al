package com.lab;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import java.security.KeyPairGenerator;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.security.Signature;

/** Deliberately mixed crypto so the CBOM scan has something to find. */
public class BadCrypto {

    // --- findings the scan should raise ---

    public byte[] legacyHash(byte[] in) throws Exception {
        MessageDigest md = MessageDigest.getInstance("MD5");      // broken
        return md.digest(in);
    }

    public byte[] legacyHash2(byte[] in) throws Exception {
        MessageDigest md = MessageDigest.getInstance("SHA-1");    // deprecated
        return md.digest(in);
    }

    public byte[] desEncrypt(byte[] data) throws Exception {
        KeyGenerator kg = KeyGenerator.getInstance("DES");        // 56-bit
        SecretKey k = kg.generateKey();
        Cipher c = Cipher.getInstance("DES/ECB/PKCS5Padding");    // ECB too
        c.init(Cipher.ENCRYPT_MODE, k);
        return c.doFinal(data);
    }

    public byte[] hardcodedIv(byte[] data) throws Exception {
        byte[] key = "0123456789abcdef".getBytes();               // hardcoded key
        byte[] iv  = new byte[16];                                // static IV
        Cipher c = Cipher.getInstance("AES/CBC/PKCS5Padding");
        c.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"), new IvParameterSpec(iv));
        return c.doFinal(data);
    }

    public void weakRsa() throws Exception {
        KeyPairGenerator kpg = KeyPairGenerator.getInstance("RSA");
        kpg.initialize(1024);                                     // Shor-broken and weak today
        kpg.generateKeyPair();
    }

    public void rsa2048() throws Exception {
        KeyPairGenerator kpg = KeyPairGenerator.getInstance("RSA");
        kpg.initialize(2048);                                     // Shor-broken
        kpg.generateKeyPair();
    }

    public void ecdsaSign(byte[] data) throws Exception {
        KeyPairGenerator kpg = KeyPairGenerator.getInstance("EC");
        kpg.initialize(256);                                      // Shor-broken
        Signature s = Signature.getInstance("SHA256withECDSA");
        s.initSign(kpg.generateKeyPair().getPrivate());
        s.update(data);
        s.sign();
    }

    // --- the one correct path, for contrast ---

    public byte[] aesGcm(byte[] data) throws Exception {
        KeyGenerator kg = KeyGenerator.getInstance("AES");
        kg.init(256);                                             // Grover-weakened only
        byte[] nonce = new byte[12];
        SecureRandom.getInstanceStrong().nextBytes(nonce);
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.ENCRYPT_MODE, kg.generateKey(), new GCMParameterSpec(128, nonce));
        return c.doFinal(data);
    }
}
