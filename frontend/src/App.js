import React from 'react';
import { Amplify } from 'aws-amplify';
import { Authenticator } from '@aws-amplify/ui-react';
import '@aws-amplify/ui-react/styles.css';
import Chat from './Chat';
import awsConfig from './aws-config';

Amplify.configure({
  Auth: {
    Cognito: {
      userPoolId: awsConfig.userPoolId,
      userPoolClientId: awsConfig.userPoolClientId,
      loginWith: { email: true },
    },
  },
});

export default function App() {
  return (
    <Authenticator
      loginMechanisms={['email']}
      variation="modal"
    >
      {({ signOut, user }) => (
        <Chat user={user} signOut={signOut} />
      )}
    </Authenticator>
  );
}
