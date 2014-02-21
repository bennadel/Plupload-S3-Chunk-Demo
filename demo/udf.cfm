<cfscript>
	
	// I generate the MD5 hash for the Content-MD5 header.
	public string function generateMd5Hash( required string body ) {

		var bytes = binaryDecode( hash( body ), "hex" );

		return( binaryEncode( bytes, "base64") );

	}


	// I help generate the signature for use with the Amazon S3 requests.
	public string function generateSignature(
		required string secretKey,
		required string method,
		required string resource,
		string md5Hash = "",
		string contentType = "",
		array amazonHeaders = [],
		date createdAt,
		numeric expiresAt
		) {

		// Start with the parts we always need.
		var parts = [
			method,
			md5Hash,
			contentType
		];

		// We either need the date the request was created or the time (in seconds) at which it
		// expires (the latter is for presigned URLs).
		if ( structKeyExists( arguments, "createdAt" ) ) {

			arrayAppend( parts, createdAt );

		} else {

			arrayAppend( parts, expiresAt );

		}

		// Add any amazon headers.
		for ( var header in amazonHeaders ) {

			arrayAppend( parts, header );

		}

		// We always need the resource.
		arrayAppend( parts, resource );

		var message = arrayToList( parts, chr( 10 ) );

		return( hmacSha1( message, secretKey, "base64" ) );

	}

	
	// I generate a hashed message authenticate code using the HmacSHA1 algorithm.
	public string function hmacSha1(
		required string message,
		required string key,
		required string encoding
		) {

		// Create the specification for our secret key.
		var secretkeySpec = createObject( "java", "javax.crypto.spec.SecretKeySpec" ).init(
			charsetDecode( key, "utf-8" ),
			javaCast( "string", "HmacSHA1" )
		);

		// Get an instance of our MAC generator.
		var mac = createObject( "java", "javax.crypto.Mac" ).getInstance(
			javaCast( "string", "HmacSHA1" )
		);

		// Initialize the Mac with our secret key spec.
		mac.init( secretkeySpec );

		// Hash the input (as a byte array).
		var hashedBytes = mac.doFinal(
			charsetDecode( message, "utf-8" )
		);

		// Use appropriate encoding.
		if ( encoding == "base64" ) {

			return( binaryEncode( hashedBytes, "base64") );

		} else if ( encoding == "hex" ) {

			return( ucase( binaryEncode( hashedBytes, "hex" ) ) );

		}

		throw( type = "UnsupportedEncoding" );

	}

</cfscript>