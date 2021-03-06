import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/digests/sha3.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';
import 'package:pointycastle/key_generators/api.dart';
import 'package:pointycastle/key_generators/ec_key_generator.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';
import 'package:web3dart/src/utils/dartrandom.dart';

import 'numbers.dart' as numbers;

final ECDomainParameters params = ECCurve_secp256k1();
final BigInt _halfCurveOrder = params.n ~/ BigInt.two;

const int _shaBytes = 256 ~/ 8;
final SHA3Digest sha3digest = SHA3Digest(_shaBytes * 8);

/// Signatures used to sign Ethereum transactions and messages.
class MsgSignature {
  final BigInt r;
  final BigInt s;
  final int v;

  MsgSignature(this.r, this.s, this.v);
}

Uint8List sha3(Uint8List input) {
  sha3digest.reset();
  return sha3digest.process(input);
}

/// Generates a new private key using the random instance provided. Please make
/// sure you're using a cryptographically secure generator.
BigInt generateNewPrivateKey(Random random) {
  final generator = ECKeyGenerator();

  final keyParams = ECKeyGeneratorParameters(params);

  generator.init(ParametersWithRandom(keyParams, DartRandom(random)));

  final key = generator.generateKeyPair();
  final privateKey = key.privateKey as ECPrivateKey;
  return privateKey.d;
}

/// Generates a public key for the given private key using the ecdsa curve which
/// Ethereum uses.
Uint8List privateKeyToPublic(Uint8List privateKey) {
  final privateKeyNum = numbers.bytesToInt(privateKey);
  final p = params.G * privateKeyNum;

  //skip the type flag, https://github.com/ethereumjs/ethereumjs-util/blob/master/index.js#L319
  return Uint8List.view(p.getEncoded(false).buffer, 1);
}

/// Constructs the Ethereum address associated with the given public key by
/// taking the lower 160 bits of the key's sha3 hash.
Uint8List publicKeyToAddress(Uint8List publicKey) {
  assert(publicKey.length == 64);

  final hashed = sha3digest.process(publicKey);
  return Uint8List.view(hashed.buffer, _shaBytes - 20);
}

/// Signs the hashed data in [messageHash] using the given private key.
MsgSignature sign(Uint8List messageHash, Uint8List privateKey) {
  final digest = SHA256Digest();
  final signer = ECDSASigner(null, HMac(digest, 64));
  final key = ECPrivateKey(numbers.bytesToInt(privateKey), params);

  signer.init(true, PrivateKeyParameter(key));
  var sig = signer.generateSignature(messageHash) as ECSignature;

  /*
	This is necessary because if a message can be signed by (r, s), it can also
	be signed by (r, -s (mod N)) which N being the order of the elliptic function
	used. In order to ensure transactions can't be tampered with (even though it
	would be harmless), Ethereum only accepts the signature with the lower value
	of s to make the signature for the message unique.
	More details at
	https://github.com/web3j/web3j/blob/master/crypto/src/main/java/org/web3j/crypto/ECDSASignature.java#L27
	 */
  if (sig.s.compareTo(_halfCurveOrder) > 0) {
    final canonicalisedS = params.n - sig.s;
    sig = ECSignature(sig.r, canonicalisedS);
  }

  final publicKey = numbers.bytesToInt(privateKeyToPublic(privateKey));

  //Implementation for calculating v naively taken from there, I don't understand
  //any of this.
  //https://github.com/web3j/web3j/blob/master/crypto/src/main/java/org/web3j/crypto/Sign.java
  var recId = -1;
  for (var i = 0; i < 4; i++) {
    final k = _recoverFromSignature(i, sig, messageHash, params);
    if (k == publicKey) {
      recId = i;
      break;
    }
  }

  if (recId == -1) {
    throw Exception(
        'Could not construct a recoverable key. This should never happen');
  }

  return MsgSignature(sig.r, sig.s, recId + 27);
}

BigInt _recoverFromSignature(
    int recId, ECSignature sig, Uint8List msg, ECDomainParameters params) {
  final n = params.n;
  final i = BigInt.from(recId ~/ 2);
  final x = sig.r + (i * n);

  //Parameter q of curve
  final prime = BigInt.parse(
      'fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f',
      radix: 16);
  if (x.compareTo(prime) >= 0) return null;

  final R = _decompressKey(x, (recId & 1) == 1, params.curve);
  if (!(R * n).isInfinity) return null;

  final e = numbers.bytesToInt(msg);

  final eInv = (BigInt.zero - e) % n;
  final rInv = sig.r.modInverse(n);
  final srInv = (rInv * sig.s) % n;
  final eInvrInv = (rInv * eInv) % n;

  final q = (params.G * eInvrInv) + (R * srInv);

  final bytes = q.getEncoded(false);
  return numbers.bytesToInt(bytes.sublist(1));
}

ECPoint _decompressKey(BigInt xBN, bool yBit, ECCurve c) {
  List<int> x9IntegerToBytes(BigInt s, int qLength) {
    //https://github.com/bcgit/bc-java/blob/master/core/src/main/java/org/bouncycastle/asn1/x9/X9IntegerConverter.java#L45
    final bytes = numbers.intToBytes(s);

    if (qLength < bytes.length) {
      return bytes.sublist(0, bytes.length - qLength);
    } else if (qLength > bytes.length) {
      final tmp = List<int>.filled(qLength, 0);

      final offset = qLength - bytes.length;
      for (var i = 0; i < bytes.length; i++) {
        tmp[i + offset] = bytes[i];
      }

      return tmp;
    }

    return bytes;
  }

  final compEnc = x9IntegerToBytes(xBN, 1 + ((c.fieldSize + 7) ~/ 8));
  compEnc[0] = yBit ? 0x03 : 0x02;
  return c.decodePoint(compEnc);
}
