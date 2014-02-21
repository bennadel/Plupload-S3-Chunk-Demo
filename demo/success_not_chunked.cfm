<cfscript>
	
	// Include the Amazon Web Service (AWS) S3 credentials.
	include "aws-credentials.cfm";

	// Include some utility methods to make the AWS interactions easier.
	include "udf.cfm";


	// ------------------------------------------------------ //
	// ------------------------------------------------------ //


	// This succss page did not have chunks. In that case, all we have to do is generate 
	// the pre-signed URL for the base Key.
	param name="url.baseKey" type="string";

	// Since the key may have characters that required url-encoding, we have to re-encode
	// the key or our signature may not match.
	urlEncodedKey = urlEncodedFormat( url.baseKey );

	// Build the S3 resource for our upload.
	resource = ( "/" & aws.bucket & "/" & urlEncodedKey );

	// The URL will only be valid for a short amount of time.
	nowInSeconds = fix( getTickCount() / 1000 );

	// Add 10 seconds.
	expirationInSeconds = ( nowInSeconds + 10 );

	// Sign the request.
	signature = generateSignature(
		secretKey = aws.secretKey,
		method = "GET",
		expiresAt = expirationInSeconds,
		resource = resource
	);

	// Prepare the signature for use in a URL (to make sure none of the characters get
	// transported improperly).
	urlEncodedSignature = urlEncodedFormat( signature );


	// ------------------------------------------------------ //
	// ------------------------------------------------------ //
	

	// Direct to the pre-signed URL.
	location( 
		url = "https://s3.amazonaws.com#resource#?AWSAccessKeyId=#aws.accessID#&Expires=#expirationInSeconds#&Signature=#urlEncodedSignature#", 
		addToken = false 
	);

</cfscript>