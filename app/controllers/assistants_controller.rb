class AssistantsController < ApplicationController
  def index
    assistant = Current.user.assistants.ordered.first
    redirect_to new_assistant_message_path(assistant), status: :see_other
  end

  def update
    assistant = Current.user.assistants.find(params[:id])
    assistant.update!(instructions: params[:instructions])
    head :ok
  end
end
